<p align="center">
  <img src="assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
</p>

<p align="center"><a href="README.md">English</a> · <b>Türkçe</b> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>

# Emetgate

**Modelin yazdığı hiçbir şey doğrulanmadan diske ulaşmaz.**

Kod yazan bir model ile kaynak ağacınız arasında duran bir doğrulama kapısı. Model bir değişiklik önerir; Emetgate onu denetler ve yalnızca denetimler geçerse yazar.

<p align="center">
  <img src="assets/demo.gif" alt="The gate refusing a placeholder and a test-breaking body and committing a correct one; a search against rg; a node edit against Read and Edit" width="900">
</p>

MCP sunucusu olarak çalışır. `emetgate lockdown`, Claude Code'u yalnızca Emetgate'in araçlarıyla başlatır; böylece her yazma kapıdan geçer.

## Bir yazma nasıl denetlenir

1. **Adres.** Değişiklik bir sembolü ve dayandığı içeriğin hash'ini belirtir. Dosya o zamandan beri değiştiyse hash eşleşmez ve değişiklik reddedilir. Değişiklik, bir gövdenin içindeki tek bir sözdizimi düğümünü (örneğin bir `if` bloğunu veya bir deyimi) içeriğinin hash'iyle de adresleyebilir ve yalnızca o düğümün yeni metnini gönderir.
2. **Yerleştirme ve yeniden ayrıştırma.** Yeni gövde, bayt aralığına göre tam olarak eskisinin yerine konur. Dosya tree-sitter ile yeniden ayrıştırılır. Sözdizimi hataları, süslü parantezlerinden taşan gövdeler, yer tutucu gövdeler ve aralığın dışındaki her değişiklik reddedilir.
3. **Kanıt, olduğu yerde.** Yeniden adlandırmalar, adlardan soyutlanmış (alfa) bir hash ve TypeScript dil servisiyle çapraz denetlenen bir kapsam çözücü ile denetlenir. Taşımalar taşınan kodun hash'ini korur ve her import'u türetir. Yeni ve silinen sembollere hiçbir yerden başvurulmamalıdır.
4. **Kurallar.** CLI'dan eklediğiniz kurallar burada çalışır: yerleşik denetimler, tree-sitter sorguları (`q:`) veya kendi linter'ınız (`cmd:`).
5. **Korumalı alanda testler.** Değişiklik, deponun dışındaki bir gölge kopyaya uygulanır. Tip denetimi ve test komutlarınız orada, düşük bütünlük seviyeli bir token altında, süre, bellek ve çıktı sınırları olan bir Job Object içinde çalışır.
6. **Atomik commit.** Her toplu iş için bir write-ahead günlüğü, atomik değiştirme, dizin flush'ları. Bir çökmeden sonra `emetgate recover` toplu işi ya tümüyle eski ya tümüyle yeni bırakır.
7. **Makbuz.** Her commit bir makbuz alır: önceki ve sonraki hash'ler, kullanılan kanıt, çalıştırılan testler, uygulanan kurallar.

Bir denetim tamamlanamazsa değişiklik reddedilir. Model test komutunu, kuralları ve korumalı alan ayarlarını değiştiremez.

## Araçlar

| Araç | Ne yapar |
|---|---|
| `emetgate_explore` | Bir soru ve isteğe bağlı adlar için: adı verilen her sembolün bütün tanımları, ardından adlar, yollar ve gövdeler üzerindeki terim istatistikleriyle sıralanan fonksiyonlar ve üst düzey sabitler; her biri bütün hâlde, her satırında numarasıyla. Geri kalanlar adresleriyle listelenir |
| `emetgate_evidence` | En çok 6 adın tam kodu; birden çok dosyada tanımlı bir ad bütün tanımlarıyla döner, sembol olmayan bir ad en yakın sembollerle birlikte bildirilir |
| `emetgate_symbols`, `emetgate_skeleton` | İçerik hash'leriyle semboller ve imzalar |
| `emetgate_read_symbol` | Bir veya birkaç sembol gövdesi ya da bütün sembollere genişletilmiş bir satır aralığı; okuma bütçesini (8,192 karakter) aşan bir gövde katlanmış döner ve atlanan her satır aralığı yerinde belirtilir; `nodes:true`, bir sözdizimi düğümü başlatan her satıra hash ekler |
| `emetgate_read_file` | JSON anahtar ağacı veya tek bir pointer, Markdown başlıkları veya tek bir bölüm, metin satır aralığı (`raw:true` ile kaynak dosyada da) |
| `emetgate_list`, `emetgate_search` | Depo içinde dosyalar ve metin araması |
| `emetgate_git` | Salt okunur `status`, `diff`, `log`, `show` |
| `emetgate_mutate` | Önerilen bir gövdeyi yazmadan denetler |
| `emetgate_try`, `emetgate_try_batch` | Sembolleri, tek sözdizimi düğümlerini ve dosyaları değiştirir, oluşturur veya siler; tek değişiklik ya da atomik bir toplu iş |
| `emetgate_write_doc` | JSON pointer, Markdown bölümü veya metin aralığı yazımı; tek başına ya da kodla aynı toplu işte |
| `emetgate_rename` | Bir fonksiyonu, sınıfı, değişkeni, tipi veya enum'u kullanıldığı her yerde yeniden adlandırır |
| `emetgate_move` | Bir bildirimi başka bir dosyaya taşır; import'ları çekirdek türetir |
| `emetgate_move_file` | Bir dosyayı taşır veya yeniden adlandırır ve ona giden ve ondan çıkan her import'u yeniden yazar |
| `emetgate_run` | `--allow-run` ile izin verdiğiniz bir komutu gölge kopyada çalıştırır |
| `emetgate_scan` | Tek bir kuralı depoya karşı ölçer |

`--mirror` açıkken okumalar bir oturum içinde hiçbir şeyi tekrarlamaz: değişmemiş bir sembol, hash'iyle birlikte tek satır olarak döner.

`emetgate lockdown`, Claude Code'u hiçbir yerleşik araç olmadan, yalnızca `.mcp.json` sunucularıyla ve araç araması kapalı olarak başlatır. Depoyu değiştirmeyen ve komut çalıştırmayan on bir aracı `--allowedTools` ile geçirir; böylece `emetgate_explore`, `emetgate_evidence`, `emetgate_symbols`, `emetgate_skeleton`, `emetgate_read_symbol`, `emetgate_read_file`, `emetgate_list`, `emetgate_search`, `emetgate_scan`, `emetgate_git` ve `emetgate_mutate` izin denetimi olmadan çalışır. Yazan veya komut çalıştıran araçlar seçtiğiniz izin modunu korur; lockdown bu modu yalnızca `bypassPermissions` ise reddeder. n8n üzerinde kısa bir okuma sorusu 3 turdan 2 tura, sıcak bir arama çağrısı yaklaşık 640 ms'den yaklaşık 60 ms'ye indi. Her aracın gerekçesi ve ölçüm [REFERENCE.md](REFERENCE.md#lockdown) içindedir.

## Kurallar

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
emetgate rule list
```

Bir `--enforce` kuralı, kendisini bozan değişikliği testler çalışmadan önce reddeder. Kurallar yalnızca CLI'dan yazılır. Model onları okuyabilir; değiştiremez ve kaldıramaz.

## Makbuzlar

```
emetgate receipts attach            # attach pending receipts to your last commit as git notes
emetgate verify HEAD --test "npm test"
```

Makbuz, kanonik JSON (RFC 8785) biçiminde bir in-toto beyanıdır. `emetgate verify`, bir commit'i onu yazan sürece güvenmeden denetler: hash'leri ve alfa hash'leri yeniden hesaplar ve testleri korumalı alanda yeniden çalıştırır. Makbuzu olmayan bir değişiklik ya da kapıdan sonra düzenlenmiş bir dosya `unverified` olarak bildirilir, asla yeşil olarak değil.

Denetleyici, yazma yapan hiçbir kodu içe aktarmaz. Güvendiği kod: 24 dosyada 2,731 boş olmayan Zig satırı (bunların 727'si `src/verify/` altındaki 3 dosyada), ayrıca tree-sitter ve Zig standart kütüphanesi. Yalnızca makbuz biçiminden yola çıkılarak Python'da yazılmış ikinci bir denetleyici (383 boş olmayan Python satırı, artı depoya alınmış BLAKE3'te 298 satır) her verify testinde çalışır ve birincisiyle aynı sonucu vermek zorundadır.

## Ölçümler

Bir kod tabanı hakkındaki sorular; Serena, codebase-memory-mcp ve Claude Code'un kendi araçlarıyla karşılaştırma (`python tests/bench/neutral/laws.py`, 2026-10-04, `claude-sonnet-5-5`, her koşu için deponun taze bir kopyası, ek istem yok, soru başına üç koşu). Puan, cevap anahtarındaki maddelerden cevapta bulunanların oranıdır; anahtarlar hiçbir araç çalışmadan önce yazıldı.

| Depolar | Araç | Puan | Token | API süresi | Maliyet |
|---|---|---:|---:|---:|---:|
| nest, typeorm, actual (10 soru) | Emetgate | 0.944 | 133k | 30.0 s | $0.147 |
| | Serena | 0.963 | 165k | 36.4 s | $0.158 |
| | Claude Code'un kendi araçları | 0.926 | 193k | 35.7 s | $0.168 |
| | codebase-memory-mcp | 0.975 | 199k | 42.0 s | $0.230 |
| OpenBot (5 soru) | Emetgate | 0.956 | 97k | 22.7 s | $0.108 |
| | Serena | 0.956 | 102k | 24.5 s | $0.114 |
| | Claude Code'un kendi araçları | 0.933 | 129k | 24.3 s | $0.114 |
| | codebase-memory-mcp | 0.978 | 137k | 35.1 s | $0.152 |

Emetgate'in puanı iki sette de codebase-memory-mcp'nin, ilk sette Serena'nın da altındadır. Düzenek, kaydedilmiş 300 oturum ve bu karşılaştırmanın sınırları [tests/bench/neutral](tests/bench/neutral) içindedir.

Sık yapılan okumalar için token sayıları, Claude Code'un `Read` aracına karşı (o200k_base, `python tests/bench/reader.py`, 2026-09-26):

| Görev | Read | Emetgate |
|---|---:|---:|
| 1.6k satırlık bir dosyada tek bir fonksiyonu bulup okumak | 13,313 | 2,819 |
| 50 KB'lık bir `package-lock.json` içinde tek bir anahtarı okumak | 19,859 | 319 |
| Bir README'nin tek bir bölümünü okumak | 15,432 | 1,541 |
| Aynı sembolü oturum içinde yeniden okumak | 13,313 | 84 |
| 3 satırlık bir sembolü değiştikten sonra yeniden okumak | 18 | 74 |

Son satır daha kötüdür: cevap, sonraki düzenlemenin ihtiyaç duyduğu hash'i taşır.

Bütün düzenlemeler için token sayıları, Claude Code'un `Read` ve ardından `Edit` araçlarına karşı (o200k_base, iki taraf da model bağlamının tuttuğu `tool_use` ve `tool_result` blokları olarak sayıldı, `python tests/bench/write_flow.py`, 2026-09-27, aynı 1.6k satırlık dosya):

| Görev | Read + Edit | Emetgate |
|---|---:|---:|
| Büyük bir fonksiyonda tek satırı değiştirmek | 24,646 | 2,145 |
| Bir `if` bloğunu değiştirmek | 24,703 | 2,191 |
| Küçük bir fonksiyonu bütünüyle değiştirmek | 24,734 | 502 |
| Bir fonksiyonu ve tek çağrı yerini silmek | 24,934 | 810 |
| Tek dosyada iki düzenleme | 24,813 | 2,213 |
| Zaten okunmuş bir dosyada tek satırı değiştirmek | 139 | 191 |

Son satır daha kötüdür. Dosya zaten bağlamdayken `Edit` değişen satırı gönderir ve tek satır geri alır; emetgate'in başarı durumundaki varsayılan cevabı durum ve yeni hash'lerdir (gölge kopya notu, makbuz kimlikleri ve eski hash için `detail:"full"` gerekir) ve yalnızca argümanları bile en çok 1.9x'e izin verirdi. Emetgate ayrıca her düzenlemede testleri çalıştırır; düzenleme başına 200 ila 420 ms'lik süresinin çoğu budur. Kural, sorgu ve tam yazma ölçümleri [REFERENCE.md](REFERENCE.md) içindedir.

`rg` ve `git grep` ile karşılaştırmalı arama (`python tests/bench/search.py`, ReleaseFast): yeni bir oturumun ilk araması 5.5 ila 22.7 ms, sonraki aramalar 1.9 ila 10.1 ms; rg 27.2 ila 80.9 ms, git grep 29.1 ila 65.7 ms. İndeksin ilk kez kurulması, depo başına bir kez, 91 ila 1,335 ms sürdü (2026-09-27, tarama bant genişliği 3.13 GB/s). Her arama önce bir değişiklik izleme bariyerini bekler; böylece çağrıdan önce kapatılmış veya flush edilmiş bir yazma sonuçta yer alır. Yeni bir oturum kayıtlı indeksi yükler ve yalnızca damgaları değişen dosyaları yeniden okur. Tam tablo ve bu bariyerin kaçırdığı tek durum (dosyasını açık tutarak yazan bir süreç) [REFERENCE.md](REFERENCE.md#search) içindedir.

| Arama | rg | git grep | Emetgate, oturumda ilk | Emetgate, sonraki |
|---|---:|---:|---:|---:|
| bir hata mesajı dizgisi | 28.1 ms | 34.8 ms | 6.2 ms | 3.1 ms |
| yalnızca yorumlarda geçen bir terim | 80.9 ms | 65.7 ms | 22.7 ms | 9.9 ms |
| bir JSON anahtar değeri | 27.2 ms | 29.1 ms | 8.1 ms | 4.8 ms |
| yaygın kısa bir sözcük | 33.3 ms | 35.9 ms | 11.4 ms | 6.5 ms |
| bir regex deseni | 31.3 ms | 47.2 ms | 10.1 ms | 5.9 ms |
| tryRender kullanımları | 36.8 ms | 36.6 ms | 5.9 ms | 1.9 ms |
| logerror kullanımları | 28.4 ms | 37.9 ms | 5.5 ms | 2.1 ms |
| commit edilmiş bir yazma ve bir git commit'inin hemen ardından arama | 32.0 ms | 29.2 ms | 13.6 ms | 10.1 ms |

rg ve git grep, bir araç çağrısının başlattığı süreç olarak ölçülür; çünkü Claude Code'un Grep aracı her çağrıda rg başlatır. Emetgate, çalışan sunucusuna yapılan tek bir çağrı olarak ölçülür. Sunucunun oturum başına bir kez başlatılması ve indeksin depo başına bir kez kurulması tabloda yoktur; ikisi de REFERENCE.md içindedir.

## Kapının kendisi nasıl test edilir

- **Mutasyon testi.** Korumalar mutasyona uğratılır ve her biri için en az bir testin başarısız olması gerekir. Motor için bugün 64 mutant var: 57 öldürüldü, 4'ünün eşdeğer olduğu kanıtlandı, 2'si derinlemesine savunma olarak tutulan fazladan korumalar, 1 açık. Kaydedilen her mutant ve onu öldüren test: [VERIFICATION.md](VERIFICATION.md).
- **Model denetimi.** Commit günlüğü TLA+ ile tanımlandı ve iki ve üç dosya için TLC ile denetlendi; kurtarma sırasındaki çökmeler ve kaybolan dizin girdileri dahil.
- **Çökme testleri.** Toplu işler her adımdan sonra kesilir ve kurtarılır.
- **Kırmızı takım ve fuzz paketleri**: MCP yüzeyine, korumalı alana, günlüğe ve ayrıştırıcılara karşı.

İngilizce README'deki üretilmiş bloklarda yer alan sayılar kaynaktan üretilir ve CI'da denetlenir; bu sayfadaki sayıların onlarla aynı olduğu da CI'da denetlenir.

## Kurulum

Her sürüm, `emetgate.exe` dosyasını ve SHA-256 değerini [sürümler sayfasında](https://github.com/emetgate/emetgate/releases) yayımlar.

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

İkili dosya kod imzalı değildir; bu yüzden SmartScreen ilk çalıştırmada uyarır. Bunun yerine sağlama toplamını karşılaştırın.

## Derleme

Zig 0.16.0. tree-sitter ve gramerler depoya alınmıştır.

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## Güvenlik geçmişi

Kapıya karşı bulgular. Ayrıntılar [REFERENCE.md](REFERENCE.md#security-history) içindedir.

**F1: yazma araçları sunulan depoyla sınırlı değildi.** v0.1.2'de düzeltildi.

**F2: bir git worktree içindeki `.git` yanlış gerekçeyle reddediliyordu.** Düşük önem; düzeltildi.

**F3: reddedilen bir öneri, testleri çalışırken gerçek depoya yazabiliyordu.** v0.1.2'de düşük bütünlük seviyeli token ile düzeltildi.

**Depo defteri: commit edilmiş bir defterdeki `cmd:` kuralları onay olmadan çalışıyordu.** PR #31'de düzeltildi.

**F4: toplu iş sırasındaki bir çökme onu yarı uygulanmış bırakabiliyordu.** TLA+ ile bulundu; toplu iş commit kaydıyla düzeltildi.

**F5: test komutu `node_modules` dizinini bir junction üzerinden göremiyordu.** İşlevsel hata; hardlink ağaçlarıyla düzeltildi.

**F6: bir dosya değiştirilirken olan bir çökme yolunu boş bırakabiliyordu.** TLA+ ile bulundu; önce kopyala sonra değiştir yöntemiyle düzeltildi.

**F7: bir elektrik kesintisi toplu işi yarı uygulanmış bırakabiliyordu.** TLA+ ile bulundu; dört dizin değişikliğinin flush edilmesiyle düzeltildi.

## Sınırlar

- Yalnızca Windows; korumalı alan Job Object'leri ve bütünlük seviyelerini kullanır. Yalnızca TypeScript, JavaScript ve Zig.
- Kapıdan geçmek, kodun ayrıştırıldığı, sınırlar içinde kaldığı ve testlerinizi geçtiği anlamına gelir. Kodun doğru olduğu anlamına gelmez.
- Test kapısı, testleriniz kadar güçlüdür.
- Korumalı alan, gölge kopyanın dışına yazmayı engeller. Okumayı ve ağ erişimini engellemez. Bir AppContainer arka ucu vardır ama kullanılmaz; çünkü gerçek projeler henüz onun altında çalışmıyor.
- Kapının dışında yapılan değişiklikler kapsanmaz. Lockdown bunun içindir.
- Node.js 24.15.0 ve öncesi, Windows loopback bağlantılarında aralıklı olarak çöker; 24.16.0 veya sonrasını kullanın.

## Lisans

MIT. `vendor/` altındaki depoya alınmış gramerler kendi MIT lisanslarını korur.

<p align="center"><a href="README.md">English</a> · <b>Türkçe</b> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>
