#!/bin/bash
set -euo pipefail

/usr/bin/osascript -l JavaScript <<'JAVASCRIPT'
ObjC.import('AppKit');
var applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.seanli.clipshelf');
if (applications.count === 0) {
    console.log('ClipShelf is not running.');
} else {
    for (var index = 0; index < applications.count; index++) {
        if (!applications.objectAtIndex(index).terminate) {
            throw new Error('ClipShelf could not be asked to quit. Use its menu bar Quit command.');
        }
    }
    console.log('ClipShelf has been asked to quit.');
}
JAVASCRIPT
