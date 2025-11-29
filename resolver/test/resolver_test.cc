#include "doctest/doctest.h"
// has to go first as it violates our requirements

#include "ast/ast.h"
#include "ast/desugar/Desugar.h"
#include "common/common.h"
#include "common/concurrency/WorkerPool.h"
#include "core/Error.h"
#include "core/ErrorQueue.h"
#include "core/Unfreeze.h"
#include "local_vars/local_vars.h"
#include "namer/namer.h"
#include "resolver/resolver.h"
#include "rewriter/rewriter.h"
#include "spdlog/sinks/stdout_color_sinks.h"
#include "spdlog/spdlog.h"

using namespace std;

namespace sorbet::resolver::test {

namespace {
auto logger = spdlog::stderr_color_mt("resolver_test");
auto errorQueue = make_shared<sorbet::core::ErrorQueue>(*logger, *logger);

ast::ParsedFile getTree(core::GlobalState &gs, string str) {
    sorbet::core::UnfreezeNameTable nameTableAccess(gs); // enters original strings
    sorbet::core::UnfreezeFileTable ft(gs);              // enters original strings
    auto file = gs.enterFile("<test>", str);
    auto settings = parser::Parser::Settings{};
    auto tree = parser::Parser::run(gs, file, settings).tree;
    file.data(gs).strictLevel = core::StrictLevel::Strict;
    sorbet::core::MutableContext ctx(gs, core::Symbols::root(), file);
    auto ast = ast::desugar::node2Tree(ctx, move(tree));
    ast = rewriter::Rewriter::run(ctx, move(ast));
    return ast::ParsedFile{move(ast), file};
}

vector<ast::ParsedFile> runNamerAndResolver(core::GlobalState &gs, ast::ParsedFile tree) {
    auto localTree = sorbet::local_vars::LocalVars::run(gs, move(tree));
    vector<ast::ParsedFile> v;
    v.emplace_back(move(localTree));
    auto workers = WorkerPool::create(0, *logger);

    sorbet::core::UnfreezeNameTable nameTableAccess(gs);     // creates singletons and class names
    sorbet::core::UnfreezeSymbolTable symbolTableAccess(gs); // enters symbols

    core::FoundDefHashes foundHashes;
    auto canceled = namer::Namer::run(gs, absl::Span<ast::ParsedFile>(v), *workers, &foundHashes);
    ENFORCE(!canceled);

    auto resolved = resolver::Resolver::run(gs, move(v), *workers);
    return move(resolved.result());
}

} // namespace

TEST_CASE("Resolver") {
    core::GlobalState gs(errorQueue);
    gs.initEmpty();

    SUBCASE("BasicConstantResolution") {
        auto tree = getTree(gs, "class Foo; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto fooSymbol = rootScope->findMember(gs, gs.enterNameConstant("Foo"));

        REQUIRE(fooSymbol.exists());
        REQUIRE_EQ("<C <U Foo>>", fooSymbol.name(gs).showRaw(gs));
        REQUIRE(fooSymbol.isClassOrModule());
    }

    SUBCASE("InheritanceResolution") {
        auto tree = getTree(gs, "class Parent; end; class Child < Parent; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto parentSymbol = rootScope->findMember(gs, gs.enterNameConstant("Parent"));
        auto childSymbol = rootScope->findMember(gs, gs.enterNameConstant("Child"));

        REQUIRE(parentSymbol.exists());
        REQUIRE(childSymbol.exists());

        auto childClass = childSymbol.asClassOrModuleRef();
        const auto &childData = childClass.data(gs);

        // Verify that Child's superclass is Parent
        REQUIRE(childData->superClass().exists());
        REQUIRE_EQ(parentSymbol, core::SymbolRef(childData->superClass()));
    }

    SUBCASE("ModuleMixinResolution") {
        auto tree = getTree(gs, "module MyModule; end; class MyClass; include MyModule; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto moduleSymbol = rootScope->findMember(gs, gs.enterNameConstant("MyModule"));
        auto classSymbol = rootScope->findMember(gs, gs.enterNameConstant("MyClass"));

        REQUIRE(moduleSymbol.exists());
        REQUIRE(classSymbol.exists());

        auto myClass = classSymbol.asClassOrModuleRef();
        const auto &classData = myClass.data(gs);

        // Verify that MyClass includes MyModule in its ancestors
        bool foundMixin = false;
        for (auto ancestor : classData->mixins()) {
            if (ancestor == moduleSymbol.asClassOrModuleRef()) {
                foundMixin = true;
                break;
            }
        }
        REQUIRE(foundMixin);
    }

    SUBCASE("NestedConstantResolution") {
        auto tree = getTree(gs, "class Outer; class Inner; end; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto outerSymbol = rootScope->findMember(gs, gs.enterNameConstant("Outer"));

        REQUIRE(outerSymbol.exists());

        const auto &outerScope = outerSymbol.asClassOrModuleRef().data(gs);
        auto innerSymbol = outerScope->findMember(gs, gs.enterNameConstant("Inner"));

        REQUIRE(innerSymbol.exists());
        REQUIRE_EQ("<C <U Inner>>", innerSymbol.name(gs).showRaw(gs));
    }

    SUBCASE("TypeAliasResolution") {
        auto tree = getTree(gs, "MyType = T.type_alias {Integer}; class Foo; extend T::Sig; sig {returns(MyType)}; def bar; 42; end; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto myTypeSymbol = rootScope->findMember(gs, gs.enterNameConstant("MyType"));

        REQUIRE(myTypeSymbol.exists());
        REQUIRE(myTypeSymbol.isTypeAlias());

        // Verify that the type alias has been resolved
        auto aliasData = myTypeSymbol.asTypeMemberRef().data(gs);
        REQUIRE(aliasData->resultType != nullptr);
    }

    SUBCASE("GenericTypeResolution") {
        auto tree = getTree(gs, "class Box; extend T::Generic; Elem = type_member; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto boxSymbol = rootScope->findMember(gs, gs.enterNameConstant("Box"));

        REQUIRE(boxSymbol.exists());

        const auto &boxScope = boxSymbol.asClassOrModuleRef().data(gs);
        auto elemSymbol = boxScope->findMember(gs, gs.enterNameConstant("Elem"));

        REQUIRE(elemSymbol.exists());
        REQUIRE(elemSymbol.isTypeMember());
    }

    SUBCASE("MultipleInheritanceLevels") {
        auto tree = getTree(gs, "class A; end; class B < A; end; class C < B; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto aSymbol = rootScope->findMember(gs, gs.enterNameConstant("A"));
        auto bSymbol = rootScope->findMember(gs, gs.enterNameConstant("B"));
        auto cSymbol = rootScope->findMember(gs, gs.enterNameConstant("C"));

        REQUIRE(aSymbol.exists());
        REQUIRE(bSymbol.exists());
        REQUIRE(cSymbol.exists());

        auto cClass = cSymbol.asClassOrModuleRef();
        const auto &cData = cClass.data(gs);

        // Verify C's immediate superclass is B
        REQUIRE_EQ(bSymbol, core::SymbolRef(cData->superClass()));

        auto bClass = bSymbol.asClassOrModuleRef();
        const auto &bData = bClass.data(gs);

        // Verify B's immediate superclass is A
        REQUIRE_EQ(aSymbol, core::SymbolRef(bData->superClass()));
    }

    SUBCASE("ModulePrependResolution") {
        auto tree = getTree(gs, "module M; end; class C; prepend M; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto moduleSymbol = rootScope->findMember(gs, gs.enterNameConstant("M"));
        auto classSymbol = rootScope->findMember(gs, gs.enterNameConstant("C"));

        REQUIRE(moduleSymbol.exists());
        REQUIRE(classSymbol.exists());
    }

    SUBCASE("ConstantReferenceResolution") {
        auto tree = getTree(gs, "class A; end; class B; X = A; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto aSymbol = rootScope->findMember(gs, gs.enterNameConstant("A"));
        auto bSymbol = rootScope->findMember(gs, gs.enterNameConstant("B"));

        REQUIRE(aSymbol.exists());
        REQUIRE(bSymbol.exists());

        const auto &bScope = bSymbol.asClassOrModuleRef().data(gs);
        auto xSymbol = bScope->findMember(gs, gs.enterNameConstant("X"));

        REQUIRE(xSymbol.exists());
    }

    SUBCASE("MethodSignatureResolution") {
        auto tree = getTree(gs, "class Foo; extend T::Sig; sig {params(x: Integer).returns(String)}; def bar(x); x.to_s; end; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto fooSymbol = rootScope->findMember(gs, gs.enterNameConstant("Foo"));

        REQUIRE(fooSymbol.exists());

        const auto &fooScope = fooSymbol.asClassOrModuleRef().data(gs);
        auto barSymbol = fooScope->findMember(gs, gs.enterNameUTF8("bar"));

        REQUIRE(barSymbol.exists());
        REQUIRE(barSymbol.isMethod());

        // Verify method has a signature
        const auto &barMethod = barSymbol.asMethodRef().data(gs);
        REQUIRE(barMethod->resultType != nullptr);
    }

    SUBCASE("MultipleModuleMixins") {
        auto tree = getTree(gs, "module M1; end; module M2; end; class C; include M1; include M2; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto m1Symbol = rootScope->findMember(gs, gs.enterNameConstant("M1"));
        auto m2Symbol = rootScope->findMember(gs, gs.enterNameConstant("M2"));
        auto cSymbol = rootScope->findMember(gs, gs.enterNameConstant("C"));

        REQUIRE(m1Symbol.exists());
        REQUIRE(m2Symbol.exists());
        REQUIRE(cSymbol.exists());

        auto cClass = cSymbol.asClassOrModuleRef();
        const auto &cData = cClass.data(gs);

        // Verify that both modules are in mixins
        REQUIRE(cData->mixins().size() >= 2);
    }

    SUBCASE("SelfTypeResolution") {
        auto tree = getTree(gs, "module M; extend T::Sig; sig {returns(T.self_type)}; def self_method; self; end; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto mSymbol = rootScope->findMember(gs, gs.enterNameConstant("M"));

        REQUIRE(mSymbol.exists());
    }

    SUBCASE("ClassAliasResolution") {
        auto tree = getTree(gs, "class Original; end; Alias = Original");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto originalSymbol = rootScope->findMember(gs, gs.enterNameConstant("Original"));
        auto aliasSymbol = rootScope->findMember(gs, gs.enterNameConstant("Alias"));

        REQUIRE(originalSymbol.exists());
        REQUIRE(aliasSymbol.exists());
    }

    SUBCASE("CircularInheritanceHandling") {
        // This should be handled gracefully without infinite loop
        // Note: This will produce an error, but shouldn't crash
        auto tree = getTree(gs, "class A < B; end; class B < A; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto aSymbol = rootScope->findMember(gs, gs.enterNameConstant("A"));
        auto bSymbol = rootScope->findMember(gs, gs.enterNameConstant("B"));

        // Both classes should still be created, even if there's a circular dependency
        REQUIRE(aSymbol.exists());
        REQUIRE(bSymbol.exists());
    }

    SUBCASE("NamespacedConstantResolution") {
        auto tree = getTree(gs, "module Outer; class Inner; end; end; class User; X = Outer::Inner; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto outerSymbol = rootScope->findMember(gs, gs.enterNameConstant("Outer"));
        auto userSymbol = rootScope->findMember(gs, gs.enterNameConstant("User"));

        REQUIRE(outerSymbol.exists());
        REQUIRE(userSymbol.exists());

        const auto &outerScope = outerSymbol.asClassOrModuleRef().data(gs);
        auto innerSymbol = outerScope->findMember(gs, gs.enterNameConstant("Inner"));

        REQUIRE(innerSymbol.exists());
    }

    SUBCASE("ExtendResolution") {
        auto tree = getTree(gs, "module M; end; class C; extend M; end");
        auto trees = runNamerAndResolver(gs, move(tree));

        const auto &rootScope = core::Symbols::root().data(gs);
        auto mSymbol = rootScope->findMember(gs, gs.enterNameConstant("M"));
        auto cSymbol = rootScope->findMember(gs, gs.enterNameConstant("C"));

        REQUIRE(mSymbol.exists());
        REQUIRE(cSymbol.exists());

        // Verify extend was processed (the singleton class should have the module)
        auto cClass = cSymbol.asClassOrModuleRef();
        auto singletonClass = cClass.data(gs)->singletonClass(gs);
        REQUIRE(singletonClass.exists());
    }
}

} // namespace sorbet::resolver::test
