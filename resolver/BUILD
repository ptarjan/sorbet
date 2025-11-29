cc_library(
    name = "resolver",
    srcs = glob(
        [
            "*.cc",
            "*.h",
        ],
        exclude = [
            "*_test.cc",
            "flycheck_*",
        ],
    ),
    hdrs = [
        "resolver.h",
    ],
    linkstatic = select({
        "//tools/config:linkshared": 0,
        "//conditions:default": 1,
    }),
    visibility = ["//visibility:public"],
    deps = [
        "//ast",
        "//ast/desugar",
        "//ast/treemap",
        "//core",
        "//resolver/type_syntax",
    ],
)

cc_test(
    name = "resolver_test",
    size = "small",
    srcs = glob([
        "test/*.cc",
    ]),
    linkstatic = select({
        "//tools/config:linkshared": 0,
        "//conditions:default": 1,
    }),
    visibility = ["//tools:__pkg__"],
    deps = [
        "resolver",
        "//ast/desugar",
        "//local_vars",
        "//namer",
        "//parser",
        "//rewriter",
        "@doctest//doctest",
        "@doctest//doctest:main",
    ],
)
