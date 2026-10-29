"""Read settings anchors in their Swift view scope, including shared source files."""
from pathlib import Path
import re


def closing_brace(source, start):
    depth, index = 1, start + 1
    while index < len(source):
        if source.startswith('//', index):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end + 1
        elif source.startswith('/*', index):
            nesting, index = 1, index + 2
            while nesting and index < len(source):
                if source.startswith('/*', index):
                    nesting += 1
                    index += 2
                elif source.startswith('*/', index):
                    nesting -= 1
                    index += 2
                else:
                    index += 1
        elif source[index] == '"':
            quote = '"""' if source.startswith('"""', index) else '"'
            index += len(quote)
            while index < len(source) and not source.startswith(quote, index):
                index += 2 if source[index] == '\\' else 1
            index += len(quote)
        else:
            if source[index] == '{':
                depth += 1
            elif source[index] == '}':
                depth -= 1
                if depth == 0:
                    return index
            index += 1
    raise ValueError('Unbalanced Swift braces')


def scan(root):
    rows, sections = set(), {}
    for path in sorted(Path(root).glob('*.swift')):
        source = path.read_text()
        scopes = []
        for match in re.finditer(r'\bstruct\s+\w+[^\n{]*\{', source):
            start = match.end() - 1
            scopes.append((start, closing_brace(source, start)))
        owners = []
        for match in re.finditer(r'func highlightID\(_ \w+: String\) -> String\s*\{\s*SettingsTab\.(\w+)\.highlightID', source):
            containing = [(a, b) for a, b in scopes if a < match.start() < b]
            if containing:
                a, b = min(containing, key=lambda item: item[1] - item[0])
                owners.append((a, b, match[1]))

        def owner(position):
            matches = [(a, b, tab) for a, b, tab in owners if a < position < b]
            return min(matches, key=lambda item: item[1] - item[0])[2] if matches else None

        for match in re.finditer(r'settingsHighlight\(id: highlightID\("([^"]+)"\)\)', source):
            tab = owner(match.start())
            if tab:
                rows.add((tab, match[1]))
        # Both Section { ... } header: { Text(...) } and Section(header: Text(...)) { ... }.
        for match in re.finditer(r'\bSection\s*(?:\([^\n]*|\{)', source):
            start = source.find('{', match.start())
            if start < 0:
                continue
            end = closing_brace(source, start)
            declaration = source[match.start():start]
            header = re.search(r'(?:header:\s*Text\(|Section\(\s*)"([^"]+)"', declaration)
            if not header:
                header = re.match(r'\}\s*header:\s*\{\s*(?:.*?)Text\("([^"]+)"\)', source[end:end+260], re.S)
            if not header:
                continue
            tab = owner(match.start())
            anchor = re.search(r'settingsHighlight\(id: highlightID\("([^"]+)"\)\)', source[start:end])
            if not tab or not anchor:
                continue
            items = sections.setdefault(tab, [])
            if header[1] not in [title for title, _ in items]:
                items.append((header[1], anchor[1]))
    return rows, sections
