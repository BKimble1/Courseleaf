// A C target needs at least one translation unit. SQLite itself is linked from
// the platform; this file only anchors the target.
#include "include/CSQLite.h"

int courseleaf_csqlite_anchor(void);
int courseleaf_csqlite_anchor(void) { return SQLITE_OK; }
