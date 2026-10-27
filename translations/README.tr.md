<p align="center">
  <img src="../assets/aleph.svg" alt="Emetgate" width="190">
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

LLM'ler hızlı ve yeteneklidir — saatlerce sürecek iş dakikalar içinde. Ama kurallarınıza uyup uymamaları kendilerine kalmış: bir model "bunu asla kullanma" ifadesini okuyup yine de kullanabilir.

Alışılmış cevap daha iyi bir istem, daha uzun bir `AGENTS.md`'dir — modelden uymasının *istendiği* kurallar. Emetgate başka bir yol tutar: model ile kaynak ağacınız arasında bir katman. Atlayabileceği bir yönerge değil — geçmek zorunda olduğu bir kapı. Model bir değişiklik önerir; çekirdek onu doğrular; geçmediği sürece hiçbir şey diske ulaşmaz.

Bir MCP sunucusu olarak çalışır; Windows üzerinde, TypeScript, JavaScript ve Zig için. Aşağıda her yetenek parçalarına ayrılıyor — her parçanın ne olduğu ve burada ne yaptığı. Altında kodu ve gerçek çıktısı olmayan hiçbir iddia yok.

## Kapı

Bir değişiklik bir sembolü ve dayandığı kodun hash'ini belirtir. Emetgate yeni gövdeyi yerine koyar, dosyayı yeniden ayrıştırır, kurallarınızı çalıştırır, sonra tip denetiminizi ve testlerinizi deponun bir korumalı alan içindeki kopyasında çalıştırır. Her adım geçerse değişiklik yazılır ve bir makbuza bağlanır; herhangi bir adım başarısız olursa hiçbir şey yazılmaz.

```
proposal ─▶ reparse ─▶ rules ─▶ typecheck ─▶ tests ─▶ write + receipt  (אמת)
                  └── any step fails ─▶ nothing is written (מת)
```

| parça | ne olduğu | burada ne yaptığı |
| --- | --- | --- |
| gölge çalışma alanı | deponun yalıtılmış bir kopyası | önerilen yazma önce burada uygulanır, böylece testler ve tip denetimi gerçek ağaca dokunmadan koşar; başarısızlıkta disk hiç değişmemiştir |
| tree-sitter | artımlı bir ayrıştırıcı | değişikliğin gerçekten ayrıştığını ve ağacı bozmadığını göstermek için dosyayı yeniden ayrıştırır |
| in-toto makbuzu | bir tedarik zinciri köken (provenance) formatı | geçen her yazmayı, neyin neyden, hangi testlerle üretildiğine dair imzalı bir kayda bağlar — sonradan denetlenebilir |

## Arama

İki motor: hız için bir düz dizin, kanıt için sertifikalı bir motor.

### `emetgate_find` — düz metin araması

Diske geri gitmeden düz metin ve dizinlenebilir desen araması. Sıcakta milisaniyenin altında.

| parça | ne olduğu | burada ne yaptığı |
| --- | --- | --- |
| sonek dizisi (SA-IS) | doğrusal zamanda kurulan, metnin her sonekinin sıralı dizisi | bir literali tek bir `O(m·log n)` ikili aramada, tüm eşleşmeleriyle birlikte bulur |
| iki dalgacık ağacı (wavelet tree) | dizi üzerinde konum→dosya ve tekrar-zinciri haritaları | hangi eşleşmenin hangi dosyada olduğunu, dosyayı diskten yeniden okumadan söyler |
| mmap'lenmiş `.emet` dizini | belleğe eşlenmiş tek bir dizin dosyası | arama sırasında dosyalar yeniden açılmaz; sıcakta `~0.7–1 ms` |

### `emetgate_search` — sertifikalı arama

Sonuçla birlikte, hiçbir şeyi kaçırmadığının kanıtını da taşıyan arama.

| parça | ne olduğu | burada ne yaptığı |
| --- | --- | --- |
| trigram postingleri | sıkıştırılmış bir ters dizin (Elias-Fano / bitmap) | tüm depoyu taramadan aday dosyaları hızla daraltır |
| RFC 9162 Merkle ağacı | okunan her dosyanın SHA-256'sı üzerinde bir kök | yanıt kökü taşır, böylece tam ya da kısmi bir cevap iddia değil kanıtlanabilir olur |
| kapalı-güvenli (fail-closed) | sayılar tutmazsa sertifika `InconsistentCertificate` olarak reddedilir | yanlış bir "tam" asla gösterilmez; kuşku varsa sessiz kalır |
| NTFS değişiklik bariyeri | `ReadDirectoryChangesW` ile dosya-değişiklik bildirimi | yalnızca değişen bir dosya yeniden okunur (tazelik); kıyaslamada sıfır kaçırma |
| ripgrep'e devretme | dizinin sunamayacağı bir regex (`\b`, lookaround…) | ripgrep'e devredilir; yanıt `delegated: rg` der — yetenek kaybı yok |

Yanıt bir iddia değil kanıt taşır — gerçek çıktı:

```
$ search "InconsistentCertificate"
✓ 6 matches in 429 files            # complete, with the Merkle root
$ search "Allocator"
partial: matches 1-46 of 1617; next offset:46
$ search "zzzNeverOccurs"
✓ no match in 569 files              # even zero is proven
```

> sıcak ~1.5–3.5 ms · soğuk (dizin kurulumu) 661 ms · ripgrep ile satır satır eşit

## Kurallar

Bir kez koyduğunuz bir politika her yazmada tutulur. Model kuralları okur ve değiştiremez.

| parça | ne olduğu | burada ne yaptığı |
| --- | --- | --- |
| tree-sitter sorguları | sözdizim ağacı üzerinde yapısal eşleşmeler | kapsam/sembol/yorum denetimleri: `no_comment`, `require_comment`, `max_function_lines`, `forbid_import`… |
| regex motoru (bütçeli) | adım-sınırlı bir eşleştirici | `forbid_regex` / `no_todo`: değişen kapsamda bir desen veya işaret avı |
| `ledger.ndjson` | yalnızca ekleme yapılan bir kural defteri (`.emetgate/`) | kurallar burada yaşar; model okur ama yazamaz — politika insana ait kalır |
| commit-mesajı denetimi | bir mesaj-yüzeyi kuralı | `message:conventional`: conventional commit'ler commit anında tutulur |

```
emetgate rule add "ban lodash"        --check forbid_import:lodash --enforce
emetgate rule add "document exports"  --check require_comment --in src/ --enforce
```

## Doğrulanmış Git

`emetgate verify --branch base..head` bir dalın tüm geçmişini yeniden oynatır ve kurcalamayı belli eden bir karar döndürür.

| parça | ne olduğu | burada ne yaptığı |
| --- | --- | --- |
| blake3 hash zinciri | her sertifika = blake3(parent ‖ oid ‖ verdict ‖ receipt) | tek bir commit'i yeniden oynatın, zincirin ucu kayar — kurcalama belli olur |
| CAS ref'leri + özel dizin | çalışma ağacına dokunmadan write-tree / commit-tree | kapıdan geçmiş, makbuzlu bir commit — düzenleyicinizi rahatsız etmeden |
| TLA⁺ model denetimi | commit günlüğünün biçimsel bir modeli | bir çökmenin yarım bıraktığı bir commit tutarlı bir duruma döner — kanıtlanmış |
| in-toto makbuzları | commit'e bağlı köken (`refs/notes/emetgate`) | makbuz yok → `partial` (kapalı-güvenli); uydurma "verified" yok |
| git rev-list yeniden oynatma | `base..head` aralığını dolaşır | her biri için tek-commit doğrulamasını yeniden koşar, zinciri örer |

```
$ emetgate verify --branch main..HEAD
branch partial: 48 commit(s)          # no receipt → fail-closed
  a179a7f unverified (no receipt)  cert 84c2…

# tamper with one receipt:
branch broken: 1 commit(s)
  3ff23a0 MISMATCH  cert ec79…         # the chain tip shifted → caught
```

## Nasıl test edilir

| parça | ne olduğu | burada ne yaptığı |
| --- | --- | --- |
| mutasyon testi | kodu bilerek bozar ve paketin bunu fark edip etmediğine bakar | testlerin yalnızca geçtiğini değil, bir hatayı *yakaladığını* kanıtlar |
| TLA⁺ | commit günlüğünün bir model denetimi | çökme kurtarmasının doğruluğu, koddan ayrı olarak gerekçelendirilmiş |
| fuzz & kırmızı takım | rastgele mutasyon artı saldırı derlemleri | beklenmedik veya düşmanca girdide çökme ya da kaçış yok |
| ripgrep eşitlik kapısı | her koşuda isabet kümesini rg ile karşılaştırır | arama "hızlı ama yanlış" olamaz; satır satır denetlenir |

Motor için: 63 mutant bugün: 56 öldürüldü, 4'ünün eşdeğer olduğu kanıtlandı, 2'si derinlemesine savunma olarak tutulan fazladan koruma, 1 açık. Liste [VERIFICATION.md](../VERIFICATION.md) içindedir.

## Ölçülen

| yüzey | ölçü | sonuç |
| --- | --- | --- |
| tam test paketi | geçti / kaldı / sızdırdı | 1908 / 0 / 0 |
| arama eşitliği | rg satırları = emetgate | 1617=1617 · 6=6 · 2=2 |
| arama sıcak | medyan | 1.5–3.5 ms |
| find sıcak | medyan | 0.7–1.0 ms |
| doğrulama (kurcalanmış makbuz) | karar | broken (yakalandı) |

```
python tests/bench/n8n_search.py   ·   zig build test
```

## Kurulum

```
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

Windows · TypeScript / JavaScript / Zig. `emetgate lockdown`, ajanı yalnızca emetgate araçlarıyla, kapalı-güvenli olarak başlatır.

## Daha derine

- [REFERENCE.md](../REFERENCE.md) — her araç
- [VERIFICATION.md](../VERIFICATION.md) — makbuzlar ve kanıt
- [docs/experiments/tla](../docs/experiments/tla) — TLA⁺ modelleri
- [tests/bench](../tests/bench) — kıyaslamalar

## Sınırlar

Yalnızca Windows; TypeScript, JavaScript ve Zig. Korumalı alan yazmaları engeller, okumaları ya da ağı değil. Kapıdan geçmek, bir değişikliğin ayrıştığını ve *sizin* testlerinizi geçtiğini kanıtlar — yalnızca o testler kadar güçlüdür. Kıyaslamalar bizim kendi kıyaslamalarımız, tek bir makineden ve yeniden üretilebilir.

## İsim nereden geliyor

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/golem-ales-dark.jpg">
  <img src="../assets/golem-ales-light.jpg" alt="1899 tarihli bir kalem çizimi: Haham Loew elini kaldırır ve golemin yüzü dumanda belirir, alnında İbranice harfler" width="220" align="left">
</picture>

Prag efsanesinde golem, alnındaki **אמת** (*emet*, "hakikat") kelimesiyle hayata gelir. İlk harfi silin, **אמת** **מת** (*met*, "ölü") olur — golem durur. Kapı, bir değişiklik tuttuğunda ilk harfi yazar; başarısız bir test onu siler.

<br clear="left">

## Lisans

MIT. Bkz. [LICENSE](../LICENSE).
