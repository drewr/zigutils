#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <libgen.h>

extern char **environ;

typedef struct {
    char *org;
    char *repo;
} GitUrl;

typedef struct {
    size_t total;
    size_t current;
    const char *phase;
    size_t width;
} ProgressBar;

typedef struct {
    size_t current;
    size_t total;
} GitProgressInfo;

typedef struct {
    const char *reason;
    const char *url;
    const char *detected_format;
    const char *found_at;
    const char *expected;
} UrlParseError;

/* Helper functions */

static char *str_dup(const char *str) {
    if (!str) return NULL;
    size_t len = strlen(str);
    char *dup = malloc(len + 1);
    if (!dup) return NULL;
    memcpy(dup, str, len + 1);
    return dup;
}

static char *str_ndup(const char *str, size_t n) {
    if (!str) return NULL;
    char *dup = malloc(n + 1);
    if (!dup) return NULL;
    memcpy(dup, str, n);
    dup[n] = '\0';
    return dup;
}

static const char *str_find(const char *haystack, const char *needle) {
    if (!haystack || !needle) return NULL;
    return strstr(haystack, needle);
}

static const char *str_find_last(const char *haystack, const char *needle) {
    if (!haystack || !needle) return NULL;
    const char *last = NULL;
    const char *curr = haystack;
    while ((curr = strstr(curr, needle)) != NULL) {
        last = curr;
        curr++;
    }
    return last;
}

static int str_starts_with(const char *str, const char *prefix) {
    if (!str || !prefix) return 0;
    return strncmp(str, prefix, strlen(prefix)) == 0;
}

static int str_ends_with(const char *str, const char *suffix) {
    if (!str || !suffix) return 0;
    size_t str_len = strlen(str);
    size_t suffix_len = strlen(suffix);
    if (suffix_len > str_len) return 0;
    return strcmp(str + str_len - suffix_len, suffix) == 0;
}

static char *str_trim(const char *str) {
    if (!str) return NULL;

    const char *start = str;
    while (*start && (*start == ' ' || *start == '\t' || *start == '\n' || *start == '\r')) {
        start++;
    }

    const char *end = str + strlen(str) - 1;
    while (end >= start && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')) {
        end--;
    }

    if (end < start) return str_dup("");
    return str_ndup(start, end - start + 1);
}

static int str_to_size(const char *str, size_t *result) {
    if (!str || !result) return 0;
    char *endptr;
    unsigned long val = strtoul(str, &endptr, 10);
    if (*endptr != '\0') return 0;
    *result = val;
    return 1;
}

static void draw_progress_bar(const ProgressBar *bar) {
    if (!bar) return;

    size_t percent = (bar->total > 0) ?
        ((bar->current * 100) / bar->total) : 0;
    if (percent > 100) percent = 100;

    size_t filled = (bar->width * percent) / 100;

    printf("\r\x1b[K");
    printf("%s [", bar->phase);

    for (size_t i = 0; i < filled; i++) {
        printf("█");
    }
    for (size_t i = filled; i < bar->width; i++) {
        printf("░");
    }

    printf("] %zu%% (%zu/%zu)", percent, bar->current, bar->total);
    fflush(stdout);
}

static void finish_progress_bar(const ProgressBar *bar) {
    if (!bar) return;
    draw_progress_bar(bar);
    printf("\n");
}

static GitProgressInfo *parse_git_percentage(const char *line) {
    if (!line) return NULL;

    const char *open_paren = str_find(line, "(");
    if (!open_paren) return NULL;

    const char *close_paren = str_find(open_paren, ")");
    if (!close_paren) return NULL;

    size_t paren_len = close_paren - open_paren - 1;
    char *progress_str = str_ndup(open_paren + 1, paren_len);
    if (!progress_str) return NULL;

    const char *slash = str_find(progress_str, "/");
    if (!slash) {
        free(progress_str);
        return NULL;
    }

    size_t slash_pos = slash - progress_str;
    char *current_str = str_ndup(progress_str, slash_pos);
    if (!current_str) {
        free(progress_str);
        return NULL;
    }

    char *trimmed_current = str_trim(current_str);
    free(current_str);

    size_t current;
    if (!str_to_size(trimmed_current, &current)) {
        free(trimmed_current);
        free(progress_str);
        return NULL;
    }
    free(trimmed_current);

    char *total_str = str_dup(slash + 1);
    if (!total_str) {
        free(progress_str);
        return NULL;
    }

    const char *comma = str_find(total_str, ",");
    if (comma) {
        total_str[comma - total_str] = '\0';
    }

    char *trimmed_total = str_trim(total_str);
    free(total_str);

    size_t total;
    if (!str_to_size(trimmed_total, &total)) {
        free(trimmed_total);
        free(progress_str);
        return NULL;
    }
    free(trimmed_total);
    free(progress_str);

    GitProgressInfo *info = malloc(sizeof(GitProgressInfo));
    if (!info) return NULL;
    info->current = current;
    info->total = total;
    return info;
}

static void parse_git_progress(const char *line, ProgressBar *progress) {
    if (!line || !progress) return;

    if (str_find(line, "Counting objects:")) {
        progress->phase = "Counting  ";
        GitProgressInfo *info = parse_git_percentage(line);
        if (info) {
            progress->current = info->current;
            progress->total = info->total;
            free(info);
        }
    } else if (str_find(line, "Compressing objects:")) {
        progress->phase = "Compressing";
        GitProgressInfo *info = parse_git_percentage(line);
        if (info) {
            progress->current = info->current;
            progress->total = info->total;
            free(info);
        }
    } else if (str_find(line, "Receiving objects:")) {
        progress->phase = "Receiving ";
        GitProgressInfo *info = parse_git_percentage(line);
        if (info) {
            progress->current = info->current;
            progress->total = info->total;
            free(info);
        }
    } else if (str_find(line, "Resolving deltas:")) {
        progress->phase = "Resolving ";
        GitProgressInfo *info = parse_git_percentage(line);
        if (info) {
            progress->current = info->current;
            progress->total = info->total;
            free(info);
        }
    }
}

static void report_parse_error(const UrlParseError *err) {
    if (!err) return;

    printf("\n");
    printf("❌ Failed to parse git URL: %s\n", err->url);
    printf("   └─ %s\n", err->reason);

    if (err->detected_format) {
        printf("   └─ Detected format: %s\n", err->detected_format);
    }

    if (err->found_at) {
        printf("   └─ Found: %s\n", err->found_at);
    }

    if (err->expected) {
        printf("   └─ Expected: %s\n", err->expected);
    }

    printf("\n");
    printf("Valid URL formats:\n");
    printf("  SSH:   git@github.com:org/repo.git\n");
    printf("  HTTPS: https://github.com/org/repo.git\n");
    printf("  HTTP:  http://github.com/org/repo.git\n");
    printf("\n");
}

static GitUrl *parse_path_component(const char *path) {
    if (!path) return NULL;

    const char *slash = str_find(path, "/");
    if (!slash) return NULL;

    size_t slash_pos = slash - path;
    char *org = str_ndup(path, slash_pos);
    if (!org) return NULL;

    char *repo = str_dup(slash + 1);
    if (!repo) {
        free(org);
        return NULL;
    }

    if (str_ends_with(repo, ".git")) {
        repo[strlen(repo) - 4] = '\0';
    }

    GitUrl *url = malloc(sizeof(GitUrl));
    if (!url) {
        free(org);
        free(repo);
        return NULL;
    }

    url->org = org;
    url->repo = repo;
    return url;
}

static GitUrl *parse_git_url(const char *url) {
    if (!url) return NULL;

    if (!str_find(url, "@") && !str_find(url, "://")) {
        UrlParseError err = {
            .reason = "URL doesn't match any known git URL format",
            .url = url,
            .detected_format = "Local path or invalid format",
            .expected = "git@host:org/repo OR https://host/org/repo",
        };
        report_parse_error(&err);
        return NULL;
    }

    /* Handle SSH URLs: git@github.com:org/repo.git */
    const char *at_pos = str_find(url, "@");
    if (at_pos) {
        const char *colon_pos = str_find_last(url, ":");

        if (!colon_pos) {
            const char *host_part = at_pos + 1;
            UrlParseError err = {
                .reason = "SSH format missing colon separator",
                .url = url,
                .detected_format = "SSH (git@...)",
                .found_at = host_part,
                .expected = "git@host:org/repo",
            };
            report_parse_error(&err);
            return NULL;
        }

        const char *path = colon_pos + 1;

        if (!str_find(path, "/")) {
            UrlParseError err = {
                .reason = "Path missing org/repo separator",
                .url = url,
                .detected_format = "SSH (git@host:...)",
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            };
            report_parse_error(&err);
            return NULL;
        }

        GitUrl *result = parse_path_component(path);
        if (!result) {
            UrlParseError err = {
                .reason = "Failed to parse org/repo from path",
                .url = url,
                .detected_format = "SSH",
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            };
            report_parse_error(&err);
        }
        return result;
    }

    /* Handle HTTPS/HTTP URLs: https://github.com/org/repo.git */
    if (str_starts_with(url, "http://") || str_starts_with(url, "https://")) {
        const char *protocol_end = str_find(url, "://");
        const char *protocol = str_starts_with(url, "https://") ? "https" : "http";

        if (!protocol_end) {
            UrlParseError err = {
                .reason = "Malformed protocol",
                .url = url,
                .detected_format = "HTTP/HTTPS",
                .expected = "http:// or https://",
            };
            report_parse_error(&err);
            return NULL;
        }

        const char *after_protocol = protocol_end + 3;
        const char *slash_pos = str_find(after_protocol, "/");

        if (!slash_pos) {
            UrlParseError err = {
                .reason = "Missing path after hostname",
                .url = url,
                .detected_format = protocol,
                .found_at = after_protocol,
                .expected = "host/org/repo",
            };
            report_parse_error(&err);
            return NULL;
        }

        const char *path = slash_pos + 1;

        if (!str_find(path, "/")) {
            UrlParseError err = {
                .reason = "Path missing org/repo separator",
                .url = url,
                .detected_format = protocol,
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            };
            report_parse_error(&err);
            return NULL;
        }

        GitUrl *result = parse_path_component(path);
        if (!result) {
            UrlParseError err = {
                .reason = "Failed to parse org/repo from path",
                .url = url,
                .detected_format = protocol,
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            };
            report_parse_error(&err);
        }
        return result;
    }

    UrlParseError err = {
        .reason = "URL doesn't start with recognized protocol",
        .url = url,
        .expected = "git@... OR http://... OR https://...",
    };
    report_parse_error(&err);
    return NULL;
}

static int run_git_clone_with_progress(const char *url, const char *dest) {
    if (!url || !dest) return 0;

    int pipes[2];
    if (pipe(pipes) == -1) {
        perror("pipe");
        return 0;
    }

    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);

    char *argv[] = {
        "git",
        "clone",
        "--progress",
        (char *)url,
        (char *)dest,
        NULL
    };

    if (posix_spawn(&pid, "/usr/bin/git", &actions, NULL, argv, environ) != 0) {
        perror("posix_spawn");
        close(pipes[0]);
        close(pipes[1]);
        posix_spawn_file_actions_destroy(&actions);
        return 0;
    }

    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);

    ProgressBar progress = {
        .total = 100,
        .current = 0,
        .phase = "",
        .width = 40,
    };

    char buffer[4096];
    char line_buffer[4096];
    size_t line_pos = 0;

    while (1) {
        ssize_t bytes_read = read(pipes[0], buffer, sizeof(buffer));
        if (bytes_read <= 0) break;

        for (ssize_t i = 0; i < bytes_read; i++) {
            char c = buffer[i];

            if (c == '\r' || c == '\n') {
                if (line_pos > 0) {
                    line_buffer[line_pos] = '\0';
                    parse_git_progress(line_buffer, &progress);
                    draw_progress_bar(&progress);
                    line_pos = 0;
                }
                if (c == '\n') line_pos = 0;
            } else if (line_pos < sizeof(line_buffer) - 1) {
                line_buffer[line_pos++] = c;
            }
        }
    }

    close(pipes[0]);

    int status;
    waitpid(pid, &status, 0);
    finish_progress_bar(&progress);

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "git clone failed\n");
        return 0;
    }

    return 1;
}

static char *path_join(const char *a, const char *b) {
    if (!a || !b) return NULL;

    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    char *result = malloc(len_a + len_b + 2);
    if (!result) return NULL;

    memcpy(result, a, len_a);
    result[len_a] = '/';
    memcpy(result + len_a + 1, b, len_b);
    result[len_a + len_b + 1] = '\0';

    return result;
}

static int mkdir_recursive(const char *path) {
    if (!path || !*path) return 1;

    char *copy = str_dup(path);
    if (!copy) return 0;

    for (char *p = copy + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(copy, 0755) == -1 && errno != EEXIST) {
                free(copy);
                return 0;
            }
            *p = '/';
        }
    }

    if (mkdir(copy, 0755) == -1 && errno != EEXIST) {
        free(copy);
        return 0;
    }

    free(copy);
    return 1;
}

int main(int argc, char *argv[]) {
    const char *root_dir = NULL;
    const char *git_url = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--root") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: --root requires an argument\n");
                return 1;
            }
            root_dir = argv[++i];
        } else if (!git_url) {
            git_url = argv[i];
        } else {
            fprintf(stderr, "Error: Too many arguments\n");
            return 1;
        }
    }

    if (!git_url) {
        printf("Usage: %s [--root <path>] <git-url>\n", argv[0]);
        return 1;
    }

    GitUrl *parsed = parse_git_url(git_url);
    if (!parsed) {
        return 1;
    }

    const char *base_path;
    char *home_src = NULL;

    if (root_dir) {
        base_path = root_dir;
    } else {
        const char *home = getenv("HOME");
        if (!home) {
            fprintf(stderr, "Error: Could not get HOME environment variable\n");
            free(parsed->org);
            free(parsed->repo);
            free(parsed);
            return 1;
        }
        home_src = path_join(home, "src");
        if (!home_src) {
            fprintf(stderr, "Error: Memory allocation failed\n");
            free(parsed->org);
            free(parsed->repo);
            free(parsed);
            return 1;
        }
        base_path = home_src;
    }

    char *org_path = path_join(base_path, parsed->org);
    if (!org_path) {
        fprintf(stderr, "Error: Memory allocation failed\n");
        free(home_src);
        free(parsed->org);
        free(parsed->repo);
        free(parsed);
        return 1;
    }

    char *full_path = path_join(org_path, parsed->repo);
    if (!full_path) {
        fprintf(stderr, "Error: Memory allocation failed\n");
        free(org_path);
        free(home_src);
        free(parsed->org);
        free(parsed->repo);
        free(parsed);
        return 1;
    }

    if (!mkdir_recursive(org_path)) {
        fprintf(stderr, "Error: Could not create directory %s\n", org_path);
        free(full_path);
        free(org_path);
        free(home_src);
        free(parsed->org);
        free(parsed->repo);
        free(parsed);
        return 1;
    }

    printf("Cloning %s into %s\n", git_url, full_path);

    int success = run_git_clone_with_progress(git_url, full_path);

    free(full_path);
    free(org_path);
    free(home_src);
    free(parsed->org);
    free(parsed->repo);
    free(parsed);

    if (!success) {
        return 1;
    }

    printf("Successfully cloned to %s\n", full_path);
    return 0;
}
