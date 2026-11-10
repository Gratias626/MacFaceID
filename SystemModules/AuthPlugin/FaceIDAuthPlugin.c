/*
 * FaceIDAuthPlugin.c
 * macOS SecurityAgent Authorization Plugin (system.login.screensaver / system.login.console)
 * Integrates MacBook Air M2 Face ID directly into macOS Golden Gate lock screen & login window.
 *
 * Build command:
 *   clang -dynamiclib -o FaceIDAuthPlugin FaceIDAuthPlugin.c -framework Security -framework CoreFoundation
 */

#include <Security/AuthorizationPlugin.h>
#include <Security/AuthSession.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

typedef struct {
    const AuthorizationCallbacks *callbacks;
} FaceIDPluginRef;

typedef struct {
    const FaceIDPluginRef *plugin;
    AuthorizationEngineRef engine;
} FaceIDMechanismRef;

static OSStatus MechanismCreate(
    AuthorizationPluginRef inPlugin,
    AuthorizationEngineRef inEngine,
    AuthorizationMechanismId mechanismId,
    AuthorizationMechanismRef *outMechanism
) {
    FaceIDMechanismRef *mech = (FaceIDMechanismRef *)calloc(1, sizeof(FaceIDMechanismRef));
    if (!mech) return errAuthorizationInternal;
    mech->plugin = (const FaceIDPluginRef *)inPlugin;
    mech->engine = inEngine;
    *outMechanism = mech;
    return errAuthorizationSuccess;
}

static OSStatus MechanismInvoke(AuthorizationMechanismRef inMechanism) {
    FaceIDMechanismRef *mech = (FaceIDMechanismRef *)inMechanism;
    if (!mech || !mech->plugin || !mech->plugin->callbacks) {
        return errAuthorizationInternal;
    }

    const char *cli_path = "/usr/local/bin/faceid-cli";
    /*
     * 기본값을 Allow(Non-blocking Pass-through)로 설정하여,
     * Face ID가 실패하거나 카메라에 얼굴이 없더라도 후속 메커니즘인
     * loginwindow:login (Touch ID 지문 인식 + 키보드 암호 직접 입력)이
     * 절대 차단되거나 취소되지 않고 함께 작동하도록 보장합니다.
     */
    AuthorizationResult result = kAuthorizationResultAllow;

    if (access(cli_path, X_OK) == 0) {
        pid_t pid = fork();
        if (pid == 0) {
            execl(cli_path, "faceid-cli", "verify", (char *)NULL);
            _exit(127);
        } else if (pid > 0) {
            int status = 0;
            if (waitpid(pid, &status, 0) > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                /* Face ID 얼굴 인식 성공 -> SecurityAgent 컨텍스트에 인증 완료 플래그 기록 */
                const char *verified_val = "true";
                AuthorizationValue val = { strlen(verified_val), (void *)verified_val };
                mech->plugin->callbacks->SetContextValue(
                    mech->engine,
                    "com.macfaceid.verified",
                    kAuthorizationContextFlagExtractable,
                    &val
                );
            }
        }
    }

    return mech->plugin->callbacks->SetResult(mech->engine, result);
}

static OSStatus MechanismDeactivate(AuthorizationMechanismRef inMechanism) {
    FaceIDMechanismRef *mech = (FaceIDMechanismRef *)inMechanism;
    if (!mech || !mech->plugin || !mech->plugin->callbacks) {
        return errAuthorizationInternal;
    }
    return mech->plugin->callbacks->DidDeactivate(mech->engine);
}

static OSStatus MechanismDestroy(AuthorizationMechanismRef inMechanism) {
    if (inMechanism) {
        free(inMechanism);
    }
    return errAuthorizationSuccess;
}

static OSStatus PluginDestroy(AuthorizationPluginRef inPlugin) {
    if (inPlugin) {
        free(inPlugin);
    }
    return errAuthorizationSuccess;
}

static const AuthorizationPluginInterface gPluginInterface = {
    kAuthorizationPluginInterfaceVersion,
    &PluginDestroy,
    &MechanismCreate,
    &MechanismInvoke,
    &MechanismDeactivate,
    &MechanismDestroy
};

OSStatus AuthorizationPluginCreate(
    const AuthorizationCallbacks *callbacks,
    AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outPluginInterface
) {
    FaceIDPluginRef *plugin = (FaceIDPluginRef *)calloc(1, sizeof(FaceIDPluginRef));
    if (!plugin) return errAuthorizationInternal;
    plugin->callbacks = callbacks;
    *outPlugin = plugin;
    *outPluginInterface = &gPluginInterface;
    return errAuthorizationSuccess;
}

