<p align="center">
  <img src="../assets/readme/hero-once-tr.svg" alt="emetgate: bir kere söyle" width="100%">
</p>

<p align="center"><a href="../docs/QUICKSTART.md"><b>Hızlı başlangıç</b></a> · <a href="../REFERENCE.md"><b>Başvuru</b></a> · <a href="../VERIFICATION.md"><b>Doğrulama</b></a> · <a href="../examples/discount"><b>Gerçek bir oturum</b></a></p>

<p align="center"><sub><a href="../README.md">English</a> · <b>Türkçe</b> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></sub></p>

> [!NOTE]
> Şimdilik yalnızca Windows'ta çalışır. Claude Code için yazıldı; TypeScript, JavaScript, Python, C# ve Zig projelerinde kullanılır.

Ajanına "yorum satırı ekleme" dersin. Bir süre uyar. Sonra konuşma uzar, bağlam sıkıştırılır, ertesi gün yeni bir oturum açılır ve aynı yorum satırı geri gelir. CLAUDE.md'ye yazarsın; orada da bir rica olarak kalır.

emetgate'te kural konuşmanın içinde değil, ayrı bir kural defterinde durur ve ajanın her yazmasında uygulanır. Ajan kuralı çiğnerse yazma diske ulaşmaz; ajan nedenini görür ve aynı turda düzeltir.

Bu bir his değil; Claude Code'un kendi dokümantasyonu da aynısını söylüyor:

> *"CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer."* CLAUDE.md talimatları Claude'un davranışını şekillendirir, ama zorlayıcı bir katman değildir. ([code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory))

<p align="center">
  <a href="../assets/video/emetgate-reklam-tr.mp4"><img src="../assets/readme/emetgate-reklam-tr-kapak.png" alt="Video: Markdown'daki kural bir ricadır, emetgate'te bir kapıdır" width="100%"></a>
  <br><sub>Videoyu izle: ajana kuralı bilerek çiğnetmeye çalışıyoruz, kapı yine de yazmıyor.</sub>
</p>

## Nasıl çalışır

<p align="center">
  <img src="../assets/readme/pillars-once-tr.svg" alt="Bir kere söyle; kural kalır; sen görmeden düzeltir" width="100%">
</p>

### Bir kere söyle

Sohbette kalıcı bir talimat verdiğinde ("bundan sonra", "asla"), emetgate ajandan bunu kurala çevirecek `/rule` satırını önermesini ister. Onaylarsın, kural olur. Kendi kuralını tek satırda da yazabilirsin:

```
emetgate rule add "no lint suppression" --check forbid_regex:eslint-disable --enforce
```

Ya da sık rastlanan kuralların bulunduğu hazır katalogdan seçersin: `console.log` yok, yeni yorum yok, `Co-authored-by` yok:

<img src="../assets/readme/term-rules-tr.svg" alt="Terminalde emetgate rule pick ve emetgate rule add" width="100%">

### Konuşma biter, kural kalır

Kural `.emetgate/` altındaki defterde durur. Konuşma ne kadar uzarsa uzasın, bağlam sıkıştırılsa da, yarın yeni oturum açılsa da aynı kural her yazmada uygulanır.

Her projede geçerli olmasını istediğin kural genel deftere yazılır: `emetgate rule add` ya da `emetgate rule pick` komutuna `--global` ekle. Bu defter hiçbir reponun içinde değil, `%LOCALAPPDATA%\emetgate\rules` altında durur ve her reponun kendi kurallarıyla birlikte uygulanır; bir repo onu değiştiremez, silemez.

`emetgate lockdown` altında Claude Code'un kendi düzenleme ve yazma araçları kapalıdır; ajan dosyaları emetgate'in araçlarıyla değiştirir ve her değişiklik aynı kurallardan geçer. Ajanın kural ekleyecek, değiştirecek ya da silecek bir aracı yoktur; bunu deneyen bir komut önce sana sorulur.

Eski bir repoya kural eklemek bir şey kırmaz: yalnızca yeni ihlaller reddedilir.

### Sen görmeden düzeltir

Ret, satırı ve sütunuyla ajana döner; ajan aynı turda düzeltir. Sen kurala uyan sonucu görürsün.

```
rejected: rule mf97c482341f15e82 (forbid:console.log) at src\pricing.js:3:3: console.log
rejected: rule me2014a06b646515d (added:no_comment) at src\pricing.js:2:3: // clamp the percent
```

## Neden bir hook ya da ESLint yetmiyor

Claude Code'un hook'larıyla ve ESLint'le bunun bir kısmını kendin kurabilirsin. Fark şurada:

- **Kapı her yazma aracında aynı.** lockdown Claude Code'un kendi düzenleme araçlarını kapatır; düzenleme, yeniden adlandırma, taşıma ve silme aynı kurallardan geçer. Ajan bir kabuk komutuyla dosya değiştirirse bu kayda geçer, dondurulmuş yollar geri alınır ve kapıdan geçmemiş değişiklik emetgate ile commit edilemez.
- **ESLint'i ajan kapatabilir.** `eslint-disable` satırı ve `.eslintrc` ajanın düzenleyebildiği dosyalardadır. emetgate'in kuralları, ajanın değiştirecek aracı olmadığı defterdedir; `eslint-disable` eklemek de bir kurala takılabilir.
- **Değişiklik bütün olarak denetlenir.** Birden çok dosyaya dokunan bir değişiklik reponun bir kopyasında, tamamı birlikte denetlenir; geçerse hepsi yazılır, geçmezse hiçbiri.
- **Sohbetten kurala.** Söylediğin kalıcı bir talimat kural olarak önerilir; her kural için ayrı bir betik yazmazsın.

## Bunun yanında

**Arama, ne okuduğunu söyler.** Ajan "her yeri buldum" dediğinde cevap kaç dosyayı taradığını ve hepsini okuyup okumadığını gösterir. Sayılar tutmazsa sonuç gösterilmez.

<img src="../assets/readme/term-search-tr.svg" alt="Dosya sayılarıyla emetgate arama çıktısı" width="100%">

**Commit'ler kayıt taşır.** Kapıdan geçen her commit, hangi dosyaların yazıldığını ve hangi kontrollerin çalıştığını `refs/notes/emetgate` içinde taşır. Bu bir kayıttır, imza değil: sonradan neyin nasıl yazıldığını gösterir.

<img src="../assets/readme/term-verify-tr.svg" alt="emetgate verify çıktısı" width="100%">

Bir commit'i güvendiğin test komutuyla kontrol et; makbuzda kayıtlı komut asla yeniden çalıştırılmaz, bu yüzden `--test` olmadan commit `unverified` kalır:

```
emetgate verify HEAD --test "npm test"
```

**Bir oturumun maliyetini gör.** `emetgate report`, projede emetgate araçlarını çağıran son oturumu özetler: süre, model turları, input, output ve cache tokenları, USD cinsinden tahmini maliyet, isme göre araç çağrıları ve kapının yaptıkları (kabul ve red edilen yazmalar, kural ihlalleri, test çalıştırmaları, makbuzlar, commit'ler). `--session <id>` tek bir oturumu seçer, `--all` bütün oturumları tablo halinde listeler, `--json` aynı sayıları JSON olarak yazar. Tokenlar Claude Code'un kendi oturum kaydından gelir (`CLAUDE_CONFIG_DIR` ya da `~/.claude` altındaki `projects/`); maliyet model başına yerleşik liste fiyatlarıyla hesaplanır, yani faturan değil bir tahmindir.

**Ajanın neye dokunduğunu gör.** `emetgate lockdown` altında emetgate çağrıları dökümde Claude Code'un kendi araçları gibi görünür, çağrılar bir araya toplandığında da: `Read(dosya)` okunan satırlarla, `Search("…")` ilk sonuçlarla, `Update(dosya)` değişen satırlar ve çevreleriyle, `Write(dosya)`, `Bash(komut)` çıktısıyla. Bir okumanın ya da düzenlemenin yanında ince bir şerit, ajanın dosyanın şimdiye kadar hangi kısımlarını gördüğünü gösterir; ajanın hiç okumadığı bir kısmı düzenlemesi `edited without reading` diye işaretlenir. Bir okuma sürerken bir şerit dosyayı tarar; tur bitince tek bir satır turu özetler ve dokunulan her dosyayı, her birinin ne kadarının okunduğuyla listeler. Yalnızca çizer: model aynı cevapları alır. Gizli bir dosya (`.env`, anahtarlar, kimlik bilgileri) adıyla görünür, içeriğiyle asla. `emetgate lockdown --no-marks` bunu kapatır.

## Veritabanları

Ajan, gizli tuttuğun verileri görmeden projenin veritabanını okuyabilir. Bir terminalde bir kez kurarsın:

```
emetgate db add main data/app.db
emetgate db hide main users.password_hash
emetgate db mask main users.email --mode email
emetgate db block main api_keys
emetgate db protect main
```

Ajan `emetgate_db` ile okur: tabloları listeler, tarif eder, örnek satır alır ve her çağrıda tek bir `SELECT` çalıştırır; sonuç JSON, CSV ya da Markdown olur, satır, hücre boyu, yanıt boyu ve süre sınırlıdır. Dosya salt okunur açılır ve her ifade çalışmadan önce SQLite'ın yetkilendiricisinden geçer. Gizli bir sütun nerede geçerse geçsin NULL okunur (`SELECT *`, bir view, bir alt sorgu, bir `WHERE`); engellenmiş bir tablo bir view üzerinden bile reddedilir; maskeli bir sütun hangi takma adla seçilirse seçilsin maskeli döner, onu bir ifadenin içine koyan sorgu reddedilir. Kurallar değere verilen ada değil, değerin geldiği sütuna bakar.

**MongoDB** de aynı şekilde çalışır. `db add` URI'yi denetlemek için bir kez oturum açar, sonra onu parolasıyla birlikte Windows DPAPI ile mühürler:

```
emetgate db add shop "mongodb://app:secret@db.local:27017/shop?authSource=admin&tls=true"
emetgate db hide shop users.ssn
emetgate db mask shop users.email --mode email
emetgate db block shop audit_log
```

Tabloların yerini koleksiyonlar alır ve bir kural en üst düzeydeki bir alanı adlandırır. Ajan SQL yerine tek bir JSON komutu gönderir: `find` (filter, projection, sort, limit, skip), `aggregate` (pipeline), `distinct` ya da `countDocuments`. emetgate her komutu çözümler ve hiçbir şey gönderilmeden önce baştan sona dolaşır. Gizli ya da maskeli bir alanın herhangi bir yerde anılmasını (bir filtre, bir sıralama, `$expr`, noktalı bir yol, `$getField`), `$$ROOT` gibi belgenin bütününe yapılan başvuruları, sunucu tarafında çalışan JavaScript'i, `$out` ve `$merge`'ü, kuralı olan bir koleksiyona yapılan birleştirmeleri (`$lookup`, `$unionWith`, `$graphLookup`) reddeder. Çalışan pipeline gizli alanları en başta ve en sonda siler; yanıt da onları bir kez daha adlarıyla düşürür ve maskeli olanları maskeler. Bir view, yerine geçtiği pipeline gibi denetlenir.

**Yazmak senin iznine bağlı.** Ajan yalnızca okur. Veriyi değiştirmesine izin vermek için istem olarak `/db write` yaz: hook bunu kendisi yanıtlar, model görmez. Yalnızca bir sonraki isteminin turunda `emetgate_db_write` `INSERT`, `UPDATE`, `DELETE` ya da DDL (MongoDB'de `insertOne`, `insertMany`, `updateOne`, `updateMany`, `deleteOne`, `deleteMany`, `drop`) çalıştırabilir; her ifade etkilediği satır sayısıyla kayda geçer. Bir tabloyu silmek, boşaltmak ya da her satırını değiştirmek, `/db write --destructive` yazmadıysan yine reddedilir; `/db read` yazma kipini hemen kapatır.

**PostgreSQL** da aynı şekilde çalışır. URL ile eklersin. Parola `%LOCALAPPDATA%\emetgate\db\credentials` altında DPAPI ile mühürlenir, depoya hiç yazılmaz; URL'ye koymayıp `db add` komutu için `PGPASSWORD` da verebilirsin:

```
emetgate db add prod "postgres://reader@db.example.com:5432/shop?sslmode=verify-full"
emetgate db hide prod users.password_hash
emetgate db mask prod users.email --mode email
emetgate doctor
```

emetgate PostgreSQL protokolünü kendisi konuşur: SCRAM-SHA-256 ile giriş, `sslmode=verify-full` ile Windows kök sertifikalarına ya da `sslrootcert`'e karşı denetlenen TLS. Her okuma, sorgu zaman aşımı olan bir `READ ONLY` transaction içinde çalışır ve geri alınır. Bir sorgu çalışmadan önce emetgate sunucudan planını ister (`EXPLAIN (VERBOSE)`) ve planın dokunduğu her tabloyu, view ve alt sorgular dahil, kullandığı her sütunu ve fonksiyonu denetler. Gizli ya da maskeli bir sütun yalnızca doğrudan seçilebilir, o zaman NULL ya da maskeli döner; başka her yerde (`WHERE`, `ORDER BY`, `GROUP BY`, bir fonksiyon, `row_to_json(t)`, satırın tamamı `t`, `UNION`, skaler alt sorgu) sorgu reddedilir. `pg_stats` gibi sistem katalogları, `COPY` ve yerleşik listede olmayan her fonksiyon (`pg_read_file`, `lo_get`, `dblink`, `query_to_xml`, `set_config`, veritabanında tanımlı fonksiyonlar) da reddedilir. Yalnızca `SELECT` yetkisi olan bir rolle bağlan: rol süper kullanıcıysa ya da yazabiliyorsa `emetgate doctor` uyarır.

## 2 dakikada başla

PowerShell'de çalıştır, sonra yeni bir terminal aç:

```
irm https://github.com/emetgate/emetgate/releases/latest/download/install.ps1 | iex
```

Proje klasöründe:

```
emetgate doctor
emetgate rule pick 1 19 26
emetgate lockdown
```

`emetgate doctor` tek ekranlık bir kurulum kontrolüdür; her satır `ok`, `warn` ya da `FAIL` ve yanında çözümü: PATH'in hangi emetgate'i çalıştırdığı ve gölgede kalan kopyalar, yeni sürüm olup olmadığı, claude ve okuduğu config klasörü (`CLAUDE_CONFIG_DIR` ya da `~/.claude`), emetgate'in MCP sunucusu olarak nerede kayıtlı olduğu, çalışan diğer emetgate süreçleri, veri klasörünün boyutu ve bu klasörün bir git deposu olup olmadığı. `--json` aynısını JSON olarak yazar.

`emetgate lockdown` Claude Code'u yalnızca emetgate araçlarıyla başlatır. Ev klasöründen ya da sürücü kökünden değil, proje klasörünün (bir git deposu) içinden çalıştır. Adım adım: [docs/QUICKSTART.md](../docs/QUICKSTART.md).

## Kaldırma

```
emetgate uninstall
emetgate uninstall --yes
```

İlk komut hiçbir şey silmez: program klasörünü (`%LOCALAPPDATA%\Programs\emetgate`), kullanıcı PATH'indeki kaydını ve veri klasörünü (`%LOCALAPPDATA%\emetgate`, birkaç GB'a çıkabilen cache'ler) boyutuyla listeler. `--yes` bunları siler; veri klasörünü tutmak için `--keep-cache` ekle. Çalışan bir emetgate.exe kendini silemediği için program klasörü komut bittikten birkaç saniye sonra gider. Başka emetgate süreçleri çalışıyorsa PID'lerini listeler ve sen onları kapatana kadar hiçbir şey silmez. Her projedeki `.emetgate` klasörü ve `.mcp.json` kaydı kalır; onları elle sil.

### Disk kullanımı

emetgate proje başına cache'leri (arama indeksi, olgular, testlerin çalıştığı kopya) `%LOCALAPPDATA%\emetgate` altında tutar. Sunucu günde bir kez 30 gündür kullanılmayan cache'leri siler. Kendin görmek ve azaltmak için:

```
emetgate cache size                  # total, per folder and per project (--json for scripts)
emetgate cache prune --dry-run       # what would go, nothing deleted
emetgate cache prune                 # remove caches unused for 14 days (--older-than <days>)
emetgate cache prune --all           # remove every cache no running emetgate is using
```

Çalışan bir emetgate'in kiraladığı cache asla silinmez. Ortak `cache` ve `run-tmp` klasörleri (paket cache'leri ve sandbox komutlarının TEMP'i) yalnızca `--all` ile ve yalnızca başka emetgate süreci çalışmıyorken temizlenir.

## Sınırlar

- Şimdilik yalnızca Windows.
- Veritabanları: SQLite, PostgreSQL ve MongoDB; MySQL sonra gelecek. Gizli ya da maskeli sütunu olan bir SQLite veritabanını reponun dışında tut ve `emetgate db protect` çalıştır; böylece hiçbir dosya aracı ya da komut dosyanın kendisini okuyamaz. PostgreSQL'de plan denetiminin izini süremediği bir sorgu çalıştırılmaz, reddedilir; bu yüzden gizli ya da maskeli sütunları olan tablolardaki bazı geçerli sorgular da reddedilir (böyle bir sütunu döndüren bir view, `UNION` ya da skaler alt sorgu). Örtük tip dönüşümleri ve eklentilerin tanımladığı tip fonksiyonları denetimden geçmeden çalışır; en az yetkili rol son güvencedir. Bir MongoDB sunucusu parola istemeli, yoksa makinedeki her program onu doğrudan okuyabilir; emetgate yalnızca SCRAM ile oturum açar, `mongodb+srv://` adreslerini çözmez (yerine sunucuları tek tek yaz) ve TLS istemci sertifikası isteyen bir sunucuya bağlanamaz.
- Kurallar emetgate'in yazma araçlarından geçen değişikliklere uygulanır. Ajanın çalıştırdığı bir komut kapıdan geçmez: değiştirdiği dosyalar raporlanır ve dondurulmuş yollar geri alınır, ama diğer kurallar komutlara uygulanmaz. Depodaki dosyaları özyinelemesiz silen bir komut lockdown altında reddedilir; ajan onları kapıdan geçen `emetgate_delete` ile siler. `emetgate_git_write` üzerinden `git rm` de `force:true` ile bile aynı şekilde reddedilir; dosyayı diskte bırakan `git rm --cached` çalışmaya devam eder.
- Kural defteri `.emetgate/` altında bir dosyadır. Ajanın onu yazacak bir aracı yok, ama bir komutla düzenlenmesi kural komutlarını izleyen kancaya takılmaz.
- lockdown dışında, ajanın kendi araçlarıyla açılan bir oturumda kapı yoktur. MCP konuşan başka ajanlarda kapı, ajan emetgate'in araçlarını kullandığı sürece çalışır.
- Her yazma kapıda yaklaşık 0.2–0.4 sn sürer. Daha az token vaat etmiyoruz.
- Makbuzlar imzasız: commit'iyle tutarsız düzenlenmiş bir makbuzu yakalar, baştan yazılmış bir geçmişi yakalamaz.
- Yıkıcı komut kontrolü kelimelere bakar; bir sandbox değildir.

## Kaputun altı

<details>
<summary>Kapı: yeniden ayrıştırma, kurallar, tip kontrolü ve testler bir kopyada, sonra tek seferde yazma</summary>

Bir değişiklik bir sembolü ve dayandığı kodun hash'ini verir. emetgate yeni gövdeyi yerine koyar, dosyayı yeniden ayrıştırır, kuralları çalıştırır, sonra tip kontrolünü ve testleri reponun bir kopyasında, düşük yetkili bir sandbox içinde çalıştırır. Her adım geçerse yazılır; biri kalırsa hiçbir şey yazılmaz. Yazma bir journal'dan geçer; yarıda kesilirse `emetgate recover` onarır.

</details>

<details>
<summary>Kurallar: sözdizimi ağacı sorguları, desenler, komutlar, dondurulmuş yollar, commit mesajları</summary>

Kural kontrolleri sözdizimi ağacı sorguları (`no_comment`, `require_comment`, `max_function_lines`, `forbid_import`), değişen bölgede adım sınırlı regex (`forbid_regex`, `no_todo`), komutlar, dondurulmuş yollar ve commit mesajı kontrolleridir (`message:conventional`, Co-authored-by yok). `ledger.ndjson` defteri yalnızca eklenebilir; model okur, yazacak aracı yoktur. lockdown'ın sohbet kancası bir `/rule` satırını modele ulaşmadan işler ve kalıcı bir talimatı kurala çevirmeyi önerir.

</details>

<details>
<summary>Arama ve doğrulama: kullanılan teknikler</summary>

Arama bir suffix array indeksi ve trigram listeleri kullanır; cevabın tam mı kısmi mi olduğunu okunan her dosyanın SHA-256'sı üzerinde bir RFC 9162 Merkle köküyle gösterir ve ripgrep ile satır satır karşılaştırılır. Commit kayıtları in-toto biçimindedir ve `emetgate verify --branch main..HEAD --test "<cmd>"` bütün bir aralığı kontrol eder; makbuzu olmayan commit `partial` sayılır. Ayrıntılar: [REFERENCE.md](../REFERENCE.md), [VERIFICATION.md](../VERIFICATION.md).

</details>

## İsim nereden geliyor

Prag efsanesinde golem, alnına yazılan **אמת** (*emet*, "hakikat") kelimesiyle canlanır; ilk harf silinince **מת** (*met*, "ölü") olur ve durur. emetgate'te de kuralı çiğneyen değişiklik yazılmaz.

MIT. Bkz. [LICENSE](../LICENSE).
