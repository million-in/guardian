#ifndef GUARDIAN_H
#define GUARDIAN_H

#ifdef __cplusplus
extern "C" {
#endif

enum GuardianSeverityFilter {
    GUARDIAN_SEVERITY_ALL = 0,
    GUARDIAN_SEVERITY_ERRORS_ONLY = 1,
    GUARDIAN_SEVERITY_WARNINGS_ONLY = 2,
    GUARDIAN_SEVERITY_CLEAR_ERRORS = 3
};

char *guardian_analyze_source_json(
    const char *file_path,
    const char *source,
    const char *config_path,
    int severity_filter
);

char *guardian_analyze_file_json(
    const char *file_path,
    const char *config_path,
    int severity_filter
);

char *guardian_analyze_folder_json(
    const char *folder_path,
    const char *config_path,
    int severity_filter
);

void guardian_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
