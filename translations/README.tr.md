<p align="center">
  <img src="../assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
  <a href="https://github.com/emetgate/emetgate/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/emetgate/emetgate/ci.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/emetgate/emetgate/releases/latest"><img src="https://img.shields.io/github/v/release/emetgate/emetgate?style=flat-square" alt="Latest release"></a>
</p>

<p align="center"><a href="../README.md">English</a> · <b>Türkçe</b> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>

# Emetgate

Kod yazan bir model ile kaynak ağacınız arasında duran bir kapı. Model bir değişiklik önerir, Emetgate onu denetler ve değişiklik ancak denetimler geçerse diske ulaşır.

Claude Code için MCP sunucusu olarak çalışır; Windows üzerinde, TypeScript ve JavaScript projelerinde.

<p align="center">
  <img src="../assets/demo.gif" alt="A Claude Code session under emetgate lockdown: a rule is added from the prompt, the gate refuses a change that fails a test and one that breaks the rule, and commits the corrected one" width="900">
</p>

## Ne yapar

**Her yazmayı denetler.** Bir değişiklik bir sembolü ve dayandığı kodun hash'ini belirtir. Emetgate yeni gövdeyi yerine koyar, dosyayı yeniden ayrıştırır, kurallarınızı çalıştırır, sonra tip denetiminizi ve testlerinizi deponun korumalı alandaki bir kopyasında çalıştırır. Herhangi bir adım başarısız olursa hiçbir şey yazılmaz. Her commit bir makbuz bırakır; `emetgate verify` onu, yazan sürece güvenmeden sonradan yeniden denetleyebilir.

**Model için kod okur.** `emetgate_explore`, kod tabanı hakkındaki bir soruyu bütün tanımlarla ve satır numaralarıyla cevaplar. `emetgate_evidence`, adını verdiğiniz sembollerin tam kodunu döndürür. Semboller, dosyalar, arama ve git için de araçlar vardır; liste [REFERENCE.md](../REFERENCE.md#mcp-tools) içindedir.

**Kurallarınızı tutar.** Bir kuralı komut satırından bir kez eklersiniz. Model kuralları okuyabilir; değiştiremez ve kaldıramaz.

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
```

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/gate-dark.svg">
    <img src="../assets/gate-light.svg" alt="A proposed change passes your rules, then the typecheck and tests in a sandbox copy. If both hold it is written with a receipt. If either fails nothing is written." width="780">
  </picture>
</p>

## Kurulum

Her sürüm, `emetgate.exe` dosyasını ve SHA-256 değerini [sürümler sayfasında](https://github.com/emetgate/emetgate/releases) yayımlar.

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

İkili dosya kod imzalı değildir; bu yüzden SmartScreen ilk çalıştırmada uyarır. Bunun yerine sağlama toplamını karşılaştırın.

`emetgate lockdown`, Claude Code'u yalnızca Emetgate'in araçlarıyla başlatır; böylece her yazma kapıdan geçer.

Lockdown altında kuralı doğrudan isteme de yazabilirsiniz. Cevabı Emetgate verir ve satır modele hiç ulaşmaz:

```
/rule add "no comments in source" --check no_comment --enforce
/rule list
```

Bundan sonra her yazma konuşma dökümünde işaretlenir: kapı geçirdiyse yeşil **אמת**, reddettiyse kırmızı **מת**.

## Ölçümler

Dört depo hakkında 15 soruyu Emetgate, Serena, codebase-memory-mcp ve Claude Code'un kendi araçlarıyla sordum: aynı model (`claude-sonnet-5-5`), her koşu için deponun taze bir kopyası, ek istem yok, soru başına üç koşu. Puan, cevap anahtarındaki maddelerden cevabın adını andıklarının oranıdır; anahtarları hiçbir araç çalışmadan önce yazdım.

| Araç | Puan | Token | Maliyet |
|---|---:|---:|---:|
| Emetgate | 240/252 | 86.7k | $0.132 |
| Serena | 242/252 | 143.8k | $0.143 |
| Claude Code'un kendi araçları | 234/252 | 171.4k | $0.150 |
| codebase-memory-mcp | 246/252 | 178.5k | $0.204 |

Bu sette Emetgate en az token'ı harcıyor ve en ucuzu. En doğrusu değil: iki araç daha yüksek puan alıyor. 252 maddede iki maddelik fark, koşudan koşuya oynamanın içinde kalır; yani bu koşular araçları puana göre sıralamaz.

Ayrıca dört araca üç soru daha elle sordum, her biri tek koşu. Emetgate yine en az token'ı harcadı; Claude Code'un kendi araçları ise daha ucuz ve daha hızlıydı:

<p align="center">
  <img src="../tests/bench/hand/three-questions.png" alt="Three questions, four tools, one model: tokens, API time and cost of each tool" width="900">
</p>

Kaydedilen 345 oturumun maliyet hakkında gösterdikleri:

- Bir oturumun maliyetini dört token sayısı belirler ve önbelleğe yazılan bir token, oradan okunan bir token'ın 20 katı tutar. Daha az token her zaman daha düşük fatura demek değildir.
- Fazladan bir model çağrısı, yaklaşık 8,000 karakterlik araç çıktısı kadar tutar.
- Model kendi istediğini yazar. Kendi araç çağrısında adını verdiği bir madde %98.5 oranında cevaba girdi; yalnızca bir cevapta gördüğü madde %90.5 oranında.

Oturumlar, sorular, cevap anahtarları ve bu sayıları üreten betik [tests/bench/neutral](../tests/bench/neutral) içindedir. Tam cevaplarıyla birlikte elle yapılan test [tests/bench/hand](../tests/bench/hand) içindedir. Tekil okuma, düzenleme ve aramaların token sayıları [REFERENCE.md](../REFERENCE.md) içindedir.

## Kapı nasıl test edilir

- **Mutasyon testi.** Her koruma bilerek bozulur ve en az bir testin başarısız olması gerekir. Motor için bugün 64 mutant var: 57 öldürüldü, 4'ünün eşdeğer olduğu kanıtlandı, 2'si derinlemesine savunma olarak tutulan fazladan korumalar, 1 açık. Liste [VERIFICATION.md](../VERIFICATION.md) içindedir.
- **Model denetimi.** Commit günlüğü TLA+ ile tanımlandı ve kurtarma sırasındaki çökmeler dahil TLC ile denetlendi.
- **Çökme testleri.** Toplu işler her adımdan sonra kesilir ve kurtarılır.
- **Kırmızı takım ve fuzz paketleri**: MCP yüzeyine, korumalı alana, günlüğe ve ayrıştırıcılara karşı.

Kapıya karşı bulgular ve düzeltmeleri [REFERENCE.md](../REFERENCE.md#security-history) içinde listelenir.

## Sınırlar

- Yalnızca Windows. Yalnızca TypeScript, JavaScript ve Zig.
- Kapıdan geçmek, kodun ayrıştırıldığı, sınırlar içinde kaldığı ve testlerinizi geçtiği anlamına gelir. Kodun doğru olduğu anlamına gelmez; test kapısı testleriniz kadar güçlüdür.
- Korumalı alan, kopyanın dışına yazmayı engeller. Okumayı ve ağ erişimini engellemez.
- Kapının dışında yapılan değişiklikler kapsanmaz. Lockdown bunun içindir.
- Node.js 24.15.0 ve öncesi, Windows loopback bağlantılarında aralıklı olarak çöker; 24.16.0 veya sonrasını kullanın.

## İsim nereden geliyor

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/golem-ales-dark.jpg">
  <img src="../assets/golem-ales-light.jpg" alt="A pen drawing from 1899: Rabbi Loew raises his hand and the golem's face forms in smoke, Hebrew letters on its forehead" width="220" align="left">
</picture>

Prag Golemi efsanesinde Haham Loew, kilden bir figürün alnına **אמת** (*emet*, hakikat) yazar ve figür canlanır. İlk harf silinince **מת** (*met*, ölü) kalır ve golem durur.

Emetgate her yazmayı aynı kelimeyle işaretler: kapı geçirdiyse tam, reddettiyse ilk harfi silinmiş.

<sub>Mikoláš Aleš, <i>Rabbi Loew and the Golem</i>, 1899. Public domain.</sub>

<br clear="left">

## Derleme

Zig 0.16.0. tree-sitter ve gramerler depoya alınmıştır.

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## Lisans

MIT. `vendor/` altındaki depoya alınmış gramerler kendi MIT lisanslarını korur.

<p align="center"><a href="../README.md">English</a> · <b>Türkçe</b> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>
