/*
 * pam_faceid.c
 * Custom PAM Module for macOS Golden Gate (MacBook Air M2)
 * Replaces or complements pam_tid.so (Touch ID) with Face ID authentication.
 *
 * Build command:
 *   clang -dynamiclib -o pam_faceid.so pam_faceid.c -lpam
 *
 * Usage in /etc/pam.d/sudo_local:
 *   auth sufficient /usr/local/lib/pam/pam_faceid.so
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>

#ifndef FACEID_CLI_DEFAULT_PATH
#define FACEID_CLI_DEFAULT_PATH "/usr/local/bin/faceid-cli"
#endif

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    const char *cli_path = FACEID_CLI_DEFAULT_PATH;

    /* 커스텀 바이너리 경로 인자 지원 (예: bin=/path/to/faceid-cli) */
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "bin=", 4) == 0) {
            cli_path = argv[i] + 4;
        }
    }

    if (access(cli_path, X_OK) != 0) {
        /* CLI 바이너리가 없으면 기존 Touch ID / 패스워드로 자연스럽게 Fallback */
        return PAM_IGNORE;
    }

    pid_t pid = fork();
    if (pid < 0) {
        return PAM_AUTH_ERR;
    } else if (pid == 0) {
        /* 자식 프로세스: faceid-cli verify 실행 */
        execl(cli_path, "faceid-cli", "verify", (char *)NULL);
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return PAM_AUTH_ERR;
    }

    if (WIFEXITED(status)) {
        int exit_code = WEXITSTATUS(status);
        if (exit_code == 0) {
            /* Face ID 인증 성공 -> 즉시 sudo 승인 (Touch ID와 동일) */
            return PAM_SUCCESS;
        } else if (exit_code == 2) {
            /* 5회 실패 / 재부팅 후 최초 / 48시간 경과 -> 암호/Touch ID로 즉시 Fallback */
            return PAM_IGNORE;
        }
    }

    return PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    return PAM_SUCCESS;
}

