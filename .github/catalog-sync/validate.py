"""Content validation for the publish job (catalog-sync).

The agent's files are untrusted. Every line it adds or removes must match an
allowlist, and doc cells must come from catalog.json (the prod catalog, which
the agent cannot write). Messages carry file names and counts only: the log is
public and the content may be hostile.

usage:
  validate.py check <catalog.json> <plain dir> <new-scopes out>
      cwd = publish workspace with the fresh checkouts api-docs/ and core-api/.
  validate.py spec <catalog.json> <new-scopes> <spec file>
      appends the generated test block for the new ESTADUAL_<UF>_* scopes.
"""
import difflib
import json
import re
import sys

UF_NAMES = {
    "AC": "Acre", "AL": "Alagoas", "AM": "Amazonas", "AP": "Amapá", "BA": "Bahia",
    "CE": "Ceará", "DF": "Distrito Federal", "ES": "Espírito Santo", "GO": "Goiás",
    "MA": "Maranhão", "MG": "Minas Gerais", "MS": "Mato Grosso do Sul", "MT": "Mato Grosso",
    "PA": "Pará", "PB": "Paraíba", "PE": "Pernambuco", "PI": "Piauí", "PR": "Paraná",
    "RJ": "Rio de Janeiro", "RN": "Rio Grande do Norte", "RO": "Rondônia", "RR": "Roraima",
    "RS": "Rio Grande do Sul", "SC": "Santa Catarina", "SE": "Sergipe", "SP": "São Paulo",
    "TO": "Tocantins",
}
MDX = "api-docs/reference/todas-certidoes.mdx"
DISTRICTS = "api-docs/api-reference/diligences/districts.mdx"
OPENAPI = "api-docs/openapi.json"
ENUM = "core-api/src/enums/emission.enum.ts"
CONSTS = "core-api/src/consts/certificateOrder.consts.ts"
TEXT_FILES = [MDX, DISTRICTS, OPENAPI, ENUM, CONSTS]
DISTRICTS_EXAMPLE = ("paths", "/diligences/districts", "get", "responses", "200",
                     "content", "application/json", "example", "data")

# NUL/CR/C0 controls, DEL, zero-width, bidi overrides, JS line terminators, BOM.
FORBIDDEN = re.compile("[\x00-\x09\x0b-\x1f\x7f​-‏‪-‮"
                       "  ⁠-⁤⁦-⁩﻿]")
CHARS = r"[\w ºª°.,;:()/&+'–—-]"  # \w is Unicode: letters, digits, _
CELL = re.compile(CHARS + "+")
SEPARATOR = re.compile(r"^\|( *:?-+:? *\|)+$")
HEADERS = {("Certidão", "Emissor"), ("Cidade", "UF", "Certidão"), ("Sigla", "Órgão")}
ACC_OPEN = re.compile(r'^ *<Accordion title="([^"]+) \(([A-Z]{2})\)">$')
ACC_CLOSE = re.compile(r"^ *</Accordion>$")
DISTRICT_LINE = re.compile(r'^ *"([A-Z]{2})": \[((?:"[A-Z0-9_]+"(?:, )?)*)\],?$')
ENUM_LINE = re.compile(r"^ *([A-Z0-9_]+) = '([A-Z0-9_]+)',?$")
CONST_LINE = re.compile(r'^ *"(' + CHARS + r'*)",?$')
COMMENT_LINE = re.compile(r"^ *// " + CHARS + r"*$")


class Reject(Exception):
    pass


def flat(path):
    return path.replace("/", "__") + ".enc"


def read_text(path):
    data = open(path, "rb").read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise Reject("não é UTF-8")
    if FORBIDDEN.search(text):
        raise Reject("tem byte de controle, CR, NUL ou caractere invisível")
    return text


def changes(a_lines, b_lines):
    """(removed [(index in A, line)], added [(index in B, line)])."""
    removed, added = [], []
    sm = difflib.SequenceMatcher(None, a_lines, b_lines, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op in ("replace", "delete"):
            removed += [(i, a_lines[i]) for i in range(i1, i2)]
        if op in ("replace", "insert"):
            added += [(j, b_lines[j]) for j in range(j1, j2)]
    return removed, added


def cells(line):
    if not (line.startswith("| ") and line.endswith(" |")):
        return None
    parts = [c.strip() for c in line[2:-2].split(" | ")]
    if any(not c or not CELL.fullmatch(c) or "  " in c for c in parts):
        return None
    return tuple(parts)


def words_of(fragment, source):
    """True when fragment is source with some words dropped (never added or changed)."""
    if not source:
        return False
    it = iter(source.split(" "))
    return all(w in it for w in fragment.split(" "))


class Catalog:
    def __init__(self, path):
        raw = json.load(open(path, encoding="utf-8"))
        self.states = {uf: set(ds) for uf, ds in raw["states"].items()
                       if re.fullmatch(r"[A-Z]{2}", uf)}
        self.comarcas = set().union(*self.states.values()) if self.states else set()
        self.packages = raw.get("packages") or {}

    def entries(self, pattern):
        rx = re.compile(pattern)
        return [e for code, items in self.packages.items() if rx.fullmatch(code)
                for e in items if isinstance(e, dict)]

    def all_issuers(self):
        return {e.get("issuer") for items in self.packages.values() for e in items
                if isinstance(e, dict) and e.get("issuer")}


# ---------- reference/todas-certidoes.mdx ----------
def mdx_context(b_lines):
    """Per line of B: (section, accordion UF or None)."""
    ctx, section, uf = [], None, None
    for line in b_lines:
        if line.startswith("## "):
            section, uf = line[3:], None
        m = ACC_OPEN.match(line)
        if m:
            uf = m.group(2)
        ctx.append((section, uf))
        if ACC_CLOSE.match(line):
            uf = None
    return ctx


def mdx_row_ok(row, section, uf, cat):
    if section == "Certidões federais" and len(row) == 2:
        pool = cat.entries(r"FEDERAL_(CPF|CNPJ)")
    elif section == "Certidões estaduais" and uf and len(row) == 2:
        pool = cat.entries(r"ESTADUAL_%s_(CPF|CNPJ)" % uf)
    elif section == "Certidões municipais" and len(row) == 3:
        city, row_uf, name = row
        if row_uf not in cat.states:
            return False
        return any(words_of(name, e.get("name")) and words_of(city, e.get("name"))
                   for e in cat.entries(r"MUNICIPAL_%s_[A-Z0-9_]+" % row_uf))
    elif section == "Emissores" and len(row) == 2:
        return any(words_of(row[0], i) and words_of(row[1], i) for i in cat.all_issuers())
    else:
        return False
    name, issuer = row
    return any(words_of(name, e.get("name")) and words_of(issuer, e.get("issuer")) for e in pool)


def check_mdx(a, b, cat):
    a_lines, b_lines = a.split("\n"), b.split("\n")
    removed, added = changes(a_lines, b_lines)
    if len(added) > 800:
        raise Reject("mais de 800 linhas novas")
    for _, line in removed:  # removals: table/accordion structure only, never prose or the group
        if not (line == "" or SEPARATOR.match(line) or cells(line) or ACC_OPEN.match(line)
                or ACC_CLOSE.match(line)):
            raise Reject("linha removida fora de tabela/accordion")
    ctx = mdx_context(b_lines)
    for j, line in added:
        section, uf = ctx[j]
        if line == "" or SEPARATOR.match(line) or ACC_CLOSE.match(line):
            continue
        m = ACC_OPEN.match(line)
        if m:
            if section != "Certidões estaduais" or m.group(2) not in cat.states \
                    or UF_NAMES.get(m.group(2)) != m.group(1):
                raise Reject("accordion novo fora do catálogo")
            continue
        row = cells(line)
        if row is None:
            raise Reject("linha nova fora do formato")
        if row in HEADERS:
            continue
        if not mdx_row_ok(row, section, uf, cat):
            raise Reject("linha de tabela nova que não sai do catalog.json")
    # Structure of B: one group; accordions open/close in pairs, only inside it.
    groups = [i for i, l in enumerate(b_lines) if l.strip() in ("<AccordionGroup>", "</AccordionGroup>")]
    if len(groups) != 2 or b_lines[groups[0]].strip() != "<AccordionGroup>":
        raise Reject("AccordionGroup desbalanceado")
    is_open, seen = False, set()
    for i, line in enumerate(b_lines):
        m = ACC_OPEN.match(line)
        if m or ACC_CLOSE.match(line) or "Accordion" in line:
            inside = groups[0] < i < groups[1]
            if m and inside and not is_open and m.group(2) not in seen:
                is_open = True
                seen.add(m.group(2))
            elif ACC_CLOSE.match(line) and inside and is_open:
                is_open = False
            elif i not in groups:
                raise Reject("Accordion desbalanceado ou repetido")
    if is_open:
        raise Reject("Accordion desbalanceado")


# ---------- api-reference/diligences/districts.mdx ----------
def check_districts(a, b, cat):
    removed, added = changes(a.split("\n"), b.split("\n"))
    if len(added) > 100:
        raise Reject("mais de 100 linhas novas")
    for _, line in removed:
        if line != "" and not DISTRICT_LINE.match(line):
            raise Reject("linha removida fora do exemplo de comarcas")
    for _, line in added:
        if line == "":
            continue
        m = DISTRICT_LINE.match(line)
        if not m or m.group(1) not in cat.states:
            raise Reject("linha nova fora do exemplo ou UF fora do catálogo")
        if not set(re.findall(r'"([A-Z0-9_]+)"', m.group(2))) <= cat.states[m.group(1)]:
            raise Reject("comarca fora do catálogo")


# ---------- openapi.json ----------
def no_dupes(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise Reject("chave duplicada")
    return dict(pairs)


def bad_constant(_):
    raise Reject("constante não-JSON")


def leaves(node, prefix=()):
    """{path: value} for scalars and empty containers (so removals show up)."""
    out = {}
    if isinstance(node, dict) and node:
        for k, v in node.items():
            out.update(leaves(v, prefix + (k,)))
    elif isinstance(node, list) and node:
        for i, v in enumerate(node):
            out.update(leaves(v, prefix + (i,)))
    else:
        out[prefix] = node
    return out


def check_openapi(a, b, cat):
    try:
        A = json.loads(a, object_pairs_hook=no_dupes, parse_constant=bad_constant)
        B = json.loads(b, object_pairs_hook=no_dupes, parse_constant=bad_constant)
    except ValueError:
        raise Reject("não é JSON válido")
    la, lb = leaves(A), leaves(B)
    diff = [p for p in set(la) | set(lb) if p not in la or p not in lb or la[p] != lb[p]]
    if len(diff) > 500:
        raise Reject("mais de 500 mudanças")
    n = len(DISTRICTS_EXAMPLE)
    for p in diff:
        if p[:n] == DISTRICTS_EXAMPLE:
            continue
        # Request examples: only the value of an existing "state"/"district" leaf.
        if p in la and p in lb and p and p[-1] in ("state", "district") and isinstance(lb[p], str):
            if p[-1] == "state" and lb[p] in cat.states:
                continue
            if p[-1] == "district":
                state = lb.get(p[:-1] + ("state",))
                pool = cat.states.get(state, set()) if state is not None else cat.comarcas
                if lb[p] in pool:
                    continue
        raise Reject("mudança fora dos exemplos de UF/comarca")
    example = B
    for k in DISTRICTS_EXAMPLE:
        example = example.get(k) if isinstance(example, dict) else None
    if not isinstance(example, dict) or not example:
        raise Reject("exemplo de /diligences/districts sumiu")
    for uf, ds in example.items():
        if uf not in cat.states or not isinstance(ds, list) or not ds \
                or not all(isinstance(d, str) and d in cat.states[uf] for d in ds):
            raise Reject("exemplo de /diligences/districts fora do catálogo")


# ---------- core-api ----------
def block(lines, start_re, end):
    """Index range strictly inside the first block opened by start_re and closed by `end`."""
    for i, line in enumerate(lines):
        if re.match(start_re, line):
            for k in range(i + 1, len(lines)):
                if lines[k] == end:
                    return range(i + 1, k)
    raise Reject("estrutura do arquivo mudou")


def check_core(a, b, starts, end, line_ok):
    a_lines, b_lines = a.split("\n"), b.split("\n")
    a_in = [i for s in starts for i in block(a_lines, s, end)]
    b_in = [i for s in starts for i in block(b_lines, s, end)]
    removed, added = changes(a_lines, b_lines)
    if len(added) > 800:
        raise Reject("mais de 800 linhas novas")
    for side, inside in ((removed, set(a_in)), (added, set(b_in))):
        for i, line in side:
            if i not in inside or not (line == "" or COMMENT_LINE.match(line) or line_ok(line)):
                raise Reject("linha fora da allowlist (entrada de enum/array, comentário ou vazia)")
    return added


def enum_entry(line):
    m = ENUM_LINE.match(line)
    return bool(m) and m.group(1) == m.group(2)


def check(catalog_path, plain, scopes_out):
    cat = Catalog(catalog_path)
    texts = {}
    for f in TEXT_FILES:
        try:
            texts[f] = (read_text(f), read_text("%s/%s" % (plain, flat(f))))
        except Reject as e:
            raise Reject("%s: %s" % (f, e))
    steps = [
        (MDX, lambda a, b: check_mdx(a, b, cat)),
        (DISTRICTS, lambda a, b: check_districts(a, b, cat)),
        (OPENAPI, lambda a, b: check_openapi(a, b, cat)),
        (ENUM, lambda a, b: check_core(a, b, [r"export enum CertificateScope \{$"], "}", enum_entry)),
        (CONSTS, lambda a, b: check_core(
            a, b, [r"export const CERTIFICATE_ORDER: readonly string\[\] = \[$",
                   r"export const ORDERED_ISSUERS: readonly string\[\] = \["], "];",
            CONST_LINE.match)),
    ]
    added_enum = []
    for f, fn in steps:
        try:
            out = fn(*texts[f])
        except Reject as e:
            raise Reject("%s: %s" % (f, e))
        if f == ENUM:
            added_enum = out
    old = {m.group(1) for m in map(ENUM_LINE.match, texts[ENUM][0].split("\n")) if m}
    scopes = []
    for _, line in added_enum:
        m = ENUM_LINE.match(line)
        s = m and re.fullmatch(r"ESTADUAL_([A-Z]{2})_(CPF|CNPJ)", m.group(1))
        if s and m.group(1) not in old:
            scopes.append({"code": m.group(1), "uf": s.group(1), "doc": s.group(2)})
    json.dump(scopes, open(scopes_out, "w"))


# ---------- generated test ----------
SPEC_BLOCK = """
// Gerado pelo workflow catalog-sync (DiHub-Api-Docs) para os escopos estaduais novos.
describe('getStateCertificates - escopos novos (catalog-sync)', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it.each([
%s
  ] as Array<[string, string, 'CPF' | 'CNPJ', string]>)(
    'resolves %%s/%%s (%%s) to %%s',
    async (state, district, typeDocument, expectedCode) => {
      (TypeDiligenceRepository.findCertificatesByTypeCode as jest.Mock).mockResolvedValue([
        { id: `cert-${expectedCode}`, name: `Certidão ${expectedCode}` },
      ]);

      const result = await getStateCertificates({
        ...baseParms,
        typeDocument,
        placesToIssue: [{ state, district }],
        multipleStates: false,
        differentStates: false,
      });

      expect(TypeDiligenceRepository.findCertificatesByTypeCode).toHaveBeenCalledWith(expectedCode);
      expect(result).toHaveLength(1);
      expect(result[0]).toMatchObject({ state, district });
    }
  );
});
"""


def spec(catalog_path, scopes_path, spec_path):
    cat = Catalog(catalog_path)
    rows, skipped = [], []
    for s in json.load(open(scopes_path)):
        code, uf, doc = s["code"], s["uf"], s["doc"]
        if not (re.fullmatch(r"ESTADUAL_[A-Z]{2}_(CPF|CNPJ)", code) and code == "ESTADUAL_%s_%s" % (uf, doc)):
            raise Reject("escopo inválido")
        districts = sorted(d for d in cat.states.get(uf, ()) if re.fullmatch(r"[A-Z0-9_]+", d))
        if not districts:
            skipped.append(uf)
            continue
        rows.append("    ['%s', '%s', '%s', '%s']," % (uf, districts[0], doc, code))
    if rows:
        with open(spec_path, "a", encoding="utf-8") as fh:
            fh.write(SPEC_BLOCK % "\n".join(rows))
    print(",".join(sorted(set(skipped))))


def main(argv):
    try:
        if len(argv) == 5 and argv[1] == "check":
            check(argv[2], argv[3], argv[4])
        elif len(argv) == 5 and argv[1] == "spec":
            spec(argv[2], argv[3], argv[4])
        else:
            raise Reject("uso inválido")
    except Reject as e:
        print("::error::%s" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
