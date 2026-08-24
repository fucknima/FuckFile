/* Extern declarations for vendored tree-sitter language grammars.
 * Compiled into the app by the theos build; imported by Swift via the
 * FuckFile-Bridging-Header.h (no module map — theos compiles Swift
 * per-file and module-map discovery is unreliable).
 */
#ifndef TREE_SITTER_GRAMMARS_H
#define TREE_SITTER_GRAMMARS_H

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

extern const TSLanguage *tree_sitter_c(void);
extern const TSLanguage *tree_sitter_cpp(void);
extern const TSLanguage *tree_sitter_objc(void);
extern const TSLanguage *tree_sitter_swift(void);
extern const TSLanguage *tree_sitter_python(void);
extern const TSLanguage *tree_sitter_javascript(void);
extern const TSLanguage *tree_sitter_typescript(void);
extern const TSLanguage *tree_sitter_tsx(void);
extern const TSLanguage *tree_sitter_json(void);
extern const TSLanguage *tree_sitter_html(void);
extern const TSLanguage *tree_sitter_css(void);
extern const TSLanguage *tree_sitter_bash(void);
extern const TSLanguage *tree_sitter_yaml(void);
extern const TSLanguage *tree_sitter_xml(void);
extern const TSLanguage *tree_sitter_markdown(void);
extern const TSLanguage *tree_sitter_markdown_inline(void);
extern const TSLanguage *tree_sitter_sql(void);

#ifdef __cplusplus
}
#endif

#endif /* TREE_SITTER_GRAMMARS_H */
