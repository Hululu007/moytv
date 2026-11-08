#import "MoyiCoreAnchor.h"
#include <stddef.h>

extern char *MoyiRequest(char *input);
extern void MoyiFree(char *value);

void ZgjEnsureCoreLinked(void) {
    char *result = MoyiRequest(NULL);
    if (result != NULL) {
        MoyiFree(result);
    }
}
