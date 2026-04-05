import zipfile
import os
import re

script_dir = os.path.dirname(os.path.abspath(__file__))
output = os.path.join(script_dir, "SocialNotifications.zip")


def strip_dev_content(source):
    """Remove dev-only content from Lua source:
    - Blocks between -- DEV_ONLY_START and -- DEV_ONLY_END
    - All mod:info(...) calls (including multi-line ones)
    """
    lines = source.split('\n')
    result = []
    i = 0

    while i < len(lines):
        line = lines[i]

        # Skip DEV_ONLY_START ... DEV_ONLY_END blocks (inclusive)
        if line.strip() == '-- DEV_ONLY_START':
            i += 1
            while i < len(lines) and lines[i].strip() != '-- DEV_ONLY_END':
                i += 1
            i += 1  # skip the DEV_ONLY_END line itself
            # Drop the blank line that typically follows the block
            if i < len(lines) and lines[i].strip() == '':
                i += 1
            continue

        # Skip mod:info(...) calls — track paren depth to handle multi-line calls
        if re.match(r'\s*mod:info\(', line):
            depth = line.count('(') - line.count(')')
            i += 1
            while depth > 0 and i < len(lines):
                depth += lines[i].count('(') - lines[i].count(')')
                i += 1
            continue

        result.append(line)
        i += 1

    return '\n'.join(result)


with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zf:
    mod_file = os.path.join(script_dir, "SocialNotifications.mod")
    zf.write(mod_file, "SocialNotifications.mod")

    scripts_dir = os.path.join(script_dir, "scripts")
    for root, dirs, files in os.walk(scripts_dir):
        for file in files:
            full_path = os.path.join(root, file)
            arcname = os.path.relpath(full_path, script_dir)
            if file.endswith('.lua'):
                with open(full_path, 'r', encoding='utf-8') as f:
                    source = f.read()
                cleaned = strip_dev_content(source)
                zf.writestr(arcname, cleaned.encode('utf-8'))
            else:
                zf.write(full_path, arcname)

print(f"Created {output}")
input("Press Enter to close...")
