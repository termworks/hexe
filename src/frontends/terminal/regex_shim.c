#include "regex_shim.h"

#include <regex.h>
#include <stdlib.h>

struct hexe_regex_holder {
    regex_t regex;
};

hexe_regex_holder *hexe_regex_create(void) {
    return (hexe_regex_holder *)calloc(1, sizeof(hexe_regex_holder));
}

void hexe_regex_destroy(hexe_regex_holder *holder) {
    if (!holder) return;
    regfree(&holder->regex);
    free(holder);
}

int hexe_regex_compile(hexe_regex_holder *holder, const char *pattern) {
    return regcomp(&holder->regex, pattern, REG_EXTENDED | REG_NOSUB);
}

int hexe_regex_match(const hexe_regex_holder *holder, const char *text) {
    return regexec(&holder->regex, text, 0, NULL, 0);
}
