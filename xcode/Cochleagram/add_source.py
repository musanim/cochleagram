#!/usr/bin/env python3
"""Add a Swift source file to Cochleagram.xcodeproj.

The project file is generated rather than managed by Xcode, so a newly created
file is invisible to the build until it is registered here. Xcode would
normally do this when you drag a file in; this does the same thing from the
command line, which is easier to keep in step with the repository.

    ./add_source.py Sources/CochleagramApp/Whatever.swift
"""

import os
import re
import sys

PROJ = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    'Cochleagram.xcodeproj', 'project.pbxproj')


def next_uid(text):
    used = set(re.findall(r'CC([0-9A-F]{22})', text))
    n = max(int(u, 16) for u in used) + 1
    return 'CC%022X' % n


def add(path):
    rel = os.path.normpath(path)
    name = os.path.basename(rel)
    s = open(PROJ).read()

    if name in s:
        print(f'{name} is already in the project')
        return

    ref = next_uid(s)
    build = next_uid(s + ref)

    s = s.replace(
        '/* End PBXBuildFile section */',
        f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; '
        f'fileRef = {ref} /* {name} */; }};\n'
        '/* End PBXBuildFile section */')

    s = s.replace(
        '/* End PBXFileReference section */',
        f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = sourcecode.swift; path = {name}; '
        'sourceTree = "<group>"; };\n'
        '/* End PBXFileReference section */')

    # Into the CochleagramApp group, next to the other Swift files.
    s = re.sub(r'(\t\t\t\t\w{24} /\* Log\.swift \*/,\n)',
               r'\1' + f'\t\t\t\t{ref} /* {name} */,\n', s, count=1)
    if f'{ref} /* {name} */,\n' not in s:
        # Fall back to the first group that mentions main.swift.
        s = re.sub(r'(\t\t\t\t\w{24} /\* main\.swift \*/,\n)',
                   r'\1' + f'\t\t\t\t{ref} /* {name} */,\n', s, count=1)

    s = re.sub(r'(\t\t\t\t\w{24} /\* main\.swift in Sources \*/,\n)',
               r'\1' + f'\t\t\t\t{build} /* {name} in Sources */,\n',
               s, count=1)

    open(PROJ, 'w').write(s)
    print(f'added {name}  (fileRef {ref}, buildFile {build})')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for p in sys.argv[1:]:
        add(p)
