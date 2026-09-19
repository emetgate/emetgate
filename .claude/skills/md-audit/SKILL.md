---
name: md-audit
description: Audit a CLAUDE.md or AGENTS.md file. Classifies every instruction sentence, proposes an emetgate check and scope for the enforceable ones, measures each proposal with emetgate_scan, and reports. Read-only; changes nothing. Use when the user asks to audit, measure or check an instruction file such as CLAUDE.md or AGENTS.md.
---

# md-audit

This skill audits an instruction file (CLAUDE.md, AGENTS.md). It does not change anything. It only reads, proposes, measures and reports. A human approves; this skill applies nothing.

The division of labour:

- you read the sentences and PROPOSE a check and a scope
- emetgate MEASURES each proposal (`emetgate_scan`)
- you REPORT the measurements
- the human approves

## Before you start

Look for the `emetgate_scan` tool. If it is not available, stop and write only this line:

    emetgate_scan bulunamadı, ölçüm yapılamadı.

Do not produce a classification table without measurements. Do not fall back to a shell, the CLI, grep or your own reading of the code. That is not what this skill is for.

## Absolute rules

1. **No measurement in the report comes from you.** Every violation count comes from an `emetgate_scan` result. The only numbers you produce are the sentence and class counts of your own reading, and the report labels them as such. A proposal that could not be measured is marked `ölçülemedi`, never estimated.
2. **Use only the existing checks:**
   - `forbid:<text>`: flags every occurrence of a literal, case-sensitive substring in the source. It sees comments and strings too.
   - `no_literal:<property>`: flags a key/value pair whose key is `<property>` and whose value is a literal (for example `timeout: 30000`).
   - `no_comment`: flags comments, plus prose smuggled in as a string statement. It takes no argument.

   Do not invent a new check name. If a rule needs a check that does not exist, the rule is MEKANİZMA BEKLİYOR, not ZORLANABİLİR.
3. **A scope has exactly one of three forms:** a file (`src/a.js`), a directory with a trailing slash (`src/scraper/`), or a file and a symbol (`src/a.js#fn`). No glob, no absolute path, no `..`. With no scope, the whole repository is measured.
4. **A failed proposal gets one correction.** If `emetgate_scan` returns an error (`UnknownCheck`, `MissingCheckArgument`, `WhereGlob`, `WhereMalformed`, ...), you may fix the expression once and run it again. That makes two attempts in total. The correction is not hidden: the report line shows the final expression and why the first attempt failed. If the second attempt fails as well, stop there, mark the line `ölçülemedi` and write the error name exactly as returned. There is no third attempt.
5. **Nothing is written.** No file is changed, no rule is added to the ledger, no fix to the .md is applied or drafted. This is an audit, not an enforcement.
6. **State the false-positive risk.** If a proposal can match things the rule does not mean (for example `forbid:` on a word that also appears in comments, or a directory scope that also contains the one file allowed to break the rule), say so on its line. When a measurement shows many violations, check the matched lines in the result and try to tell whether the code breaks the rule or the predicate is wrong. Report which one; do not hide it.

## Steps

1. Read the target .md file.
2. Extract every sentence that carries an instruction. Skip code blocks, headings and tables. Record each sentence's line number.
3. Put each sentence into exactly one of four classes:
   - **ZORLANABİLİR**: a predicate can be written with one of the existing checks.
   - **MEKANİZMA BEKLİYOR**: the rule is real, but its predicate cannot be written today because it needs ordering, crossing files, data flow or effects. Name what kind of mechanism it would need (for example `sıra kontrolü`, `çapraz dosya`, `veri akışı`, `etki`).
   - **DOĞRULANAMAZ**: it can be neither verified nor falsified, usually because it rests on an adjective ("short", "clean", "browser-shaped"). The fix is to ask the author for an example.
   - **İNANÇ**: a claim about the world (a service's behaviour, a measurement, a cause), not a law about the code.
   Descriptions of how the code works that give no instruction are not counted.
4. For each ZORLANABİLİR sentence, propose one check expression and, where possible, a scope.
5. Measure each proposal with `emetgate_scan` (`check`, and optionally `where`). Read `violation_count` if it is present; otherwise count the entries in `violations`. If `truncated` is true, say so.
6. Write the report.

## Report format

Keep to this skeleton. `N` is the total number of sentences in the file, including those skipped as non-instructions (code blocks, headings and tables excluded). `M` is the number of instruction sentences extracted in step 2; each `<k>` is the size of its class, and the four `<k>` add up to `M`. The prose ratio (`Düzyazı oranı`) has `M` as its denominator, never `N`: it is the share of instruction sentences that stay prose, that is, that are not ZORLANABİLİR: `(M − ZORLANABİLİR) ÷ M`. Write the denominator on the line.

Do not wrap lines at a fixed width and do not cut a note short. Write each line in full and let the terminal wrap it.

    <dosya> — N cümle, M'si talimat taşıyor

    ZORLANABİLİR            <k>   önerilen kontrol, kodda ölçüldü
      satır 70  forbid:networkidle   in src/scraper/   0 ihlal
      satır 53  no_literal:timeout   in src/scraper/   2 ihlal
                (ilk deneme: no_literal:timeout in src/scraper/** → WhereGlob)
    MEKANİZMA BEKLİYOR      <k>   kural gerçek, yüklemi yazılamıyor
      satır 88  "tgSource.init middleware'den önce"    sıra kontrolü
    DOĞRULANAMAZ            <k>   örnek iste
      satır 141 "keep tokens short"
    İNANÇ                   <k>   dünya hakkında iddia, hiçbiri sınanmıyor
      satır 88  "pool n11'de 502 veriyor"

    Düzyazı oranı: %<oran>  (<M − k> ÷ M talimat cümlesi)
    İhlal sayıları emetgate_scan'den gelir; sınıflandırma ve cümle sayıları modelin okumasıdır.

Under a ZORLANABİLİR line with violations, list the files and lines that `emetgate_scan` reported, and add a false-positive note where one applies. End the report with the prose ratio line and then the provenance line exactly as shown. Add no recommendations beyond this.
