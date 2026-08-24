// FuckFile-Bridging-Header.h — theos Swift 桥接头（自动被 Swift 编译导入）。
// 面向 Swift 暴露 C 声明（tree-sitter 运行库头 + 自带 grammar 声明）。
// 注意：这份头文件同时被 vendored Runestone 的「import TreeSitter」依赖，
// 因此这里只放 C 层声明，不引 ObjC 业务头。
#include <tree_sitter/api.h>
#include <tree_sitter/parser.h>
#include "third_party/tree-sitter/grammars.h"
