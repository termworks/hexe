#ifndef HEXE_TERMINAL_REGEX_SHIM_H
#define HEXE_TERMINAL_REGEX_SHIM_H

typedef struct hexe_regex_holder hexe_regex_holder;

hexe_regex_holder *hexe_regex_create(void);
void hexe_regex_destroy(hexe_regex_holder *holder);
int hexe_regex_compile(hexe_regex_holder *holder, const char *pattern);
int hexe_regex_match(const hexe_regex_holder *holder, const char *text);

#endif
