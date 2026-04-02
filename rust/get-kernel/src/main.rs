
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use uname::uname;

const BASE_DIR: &str = "/home/olivier/dev/firecracker/rust";
const REPO_DIR: &str = "/home/olivier/dev/firecracker";

// Struct simple sans méthodes : sert uniquement à regrouper deux valeurs
// retournées par resolve_versions() en un seul type nommé.
struct VersionInfo {
    arch: String,
    ci_version: String,
}

// ── version resolution ────────────────────────────────────────────────────────

// Le type de retour Result<T, E> encode succès (Ok) ou échec (Err) sans exception.
// Ici l'erreur possible est reqwest::Error (échec réseau).
fn resolve_versions() -> Result<VersionInfo, reqwest::Error> {
    let info = uname().unwrap();
    // .clone() est nécessaire car info.machine est un String appartenant à info ;
    // on en fait une copie indépendante plutôt que de le déplacer hors de info.
    let arch = info.machine.clone();

    // Le builder permet de surcharger un seul paramètre (Policy::none)
    // sans reconstruire tout le Client à la main.
    let no_redirect = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap(); // unwrap() : panique si la construction échoue (cas très improbable)

    // ? à la fin : si send() retourne Err, on sort immédiatement de la fonction
    // en propageant cette erreur à l'appelant — équivalent d'un return Err(e).
    let res = no_redirect
        .head("https://github.com/firecracker-microvm/firecracker/releases/latest")
        .send()?;

    let latest_version = res
        .headers()
        .get("location")                        // retourne Option<&HeaderValue>
        .and_then(|x| x.to_str().ok())          // Option::and_then : applique une fn si Some, propage None sinon
                                                 // .ok() convertit Result en Option (Err → None)
        .and_then(|loc| loc.split('/').last())   // split retourne un itérateur ; last() consomme tout et retourne Option
        .expect("no location header")            // expect() = unwrap() avec un message d'erreur personnalisé
        .to_owned();                             // &str → String : on alloue une copie possédée car la valeur
                                                 // empruntée (res.headers()) ne vivra pas au-delà de ce bloc

    // rfind retourne Option<usize> (position du dernier '.').
    // On utilise match pour extraire l'indice ou retomber sur la chaîne entière.
    let ci_version = match latest_version.rfind('.') {
        Some(i) => latest_version[..i].to_owned(), // slice &str jusqu'à l'indice → on alloue un String
        None => latest_version.clone(),
    };

    println!("arch={} latest={} ci_version={}", arch, latest_version, ci_version);
    // On construit le struct avec la syntaxe "field shorthand" : arch équivaut à arch: arch
    Ok(VersionInfo { arch, ci_version })
}

// Les paramètres Option<&str> permettent d'exprimer "filtre optionnel" sans surcharger la fonction.
// None = pas de filtre, Some(".squashfs") = filtre actif.
fn resolve_s3_latest_key(
    ci_version: &str,
    arch: &str,
    file_prefix: &str,
    require_suffix: Option<&str>,
    exclude_suffix: Option<&str>,
) -> Result<String, reqwest::Error> {
    let client = reqwest::blocking::Client::new();
    let listing_url = format!(
        "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/{}/{}/{}&list-type=2",
        ci_version, arch, file_prefix
    );
    let xml = client.get(&listing_url).send()?.text()?;

    let full_prefix = format!("firecracker-ci/{}/{}/{}", ci_version, arch, file_prefix);

    // Chaîne d'itérateurs : aucune allocation intermédiaire jusqu'au .collect() final.
    let mut keys: Vec<String> = xml
        .split("<Key>")          // itérateur de &str sur le XML brut
        .skip(1)                 // le premier fragment est avant la première <Key>, on le saute
        .filter_map(|chunk|      // filter_map : combine filter + map, supprime les None automatiquement
            chunk.split("</Key>").next()  // prend ce qui précède </Key> — retourne Option<&str>
        )
        .filter(|key| key.starts_with(&full_prefix))
        // map_or(default, f) : si None retourne true (= pas de filtre), si Some(sfx) applique f
        .filter(|key| require_suffix.map_or(true, |sfx| key.ends_with(sfx)))
        .filter(|key| exclude_suffix.map_or(true, |sfx| !key.ends_with(sfx)))
        .map(|k| k.to_owned())   // &str → String : on alloue car le Vec doit posséder ses éléments
        .collect();              // matérialise l'itérateur en Vec<String>

    // Tri par tuple numérique (version_sort_key) plutôt que lexicographique
    keys.sort_by(|a, b| version_sort_key(a).cmp(&version_sort_key(b)));

    // .last() retourne Option<&String> ; on clone pour obtenir un String possédé
    Ok(keys.last().expect("no artifact found in S3 listing").clone())
}

// Retourne Vec<u64> pour que la comparaison .cmp() soit un tri numérique composante par composante
// (ex. [6,1,9] < [6,1,102]) et non lexicographique (&str "9" > "102").
fn version_sort_key(s: &str) -> Vec<u64> {
    let stem = s.split('/').last().unwrap_or(s);          // nom de fichier seul
    let stem = stem.rsplit('-').next().unwrap_or(stem);   // partie après le dernier '-'
    let stem = stem.strip_suffix(".squashfs").unwrap_or(stem); // retire l'extension si présente
    // parse::<u64>() : turbofish pour préciser le type cible de parse()
    // unwrap_or(0) : si un composant n'est pas numérique on le traite comme 0
    stem.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect()
}

// ── shared helpers ────────────────────────────────────────────────────────────

fn download_file(url: &str, dest: &Path) -> Result<(), reqwest::Error> {
    println!("downloading {} -> {}", url, dest.display());
    let client = reqwest::blocking::Client::new();
    // .bytes() charge la réponse entière en mémoire — acceptable pour des fichiers ~100 Mo
    let bytes = client.get(url).send()?.bytes()?;
    // unwrap() ici : on considère une erreur d'écriture disque comme fatale (panic acceptable)
    fs::File::create(dest).unwrap().write_all(&bytes).unwrap();
    println!("  {} bytes", bytes.len());
    Ok(())
}

// &[&str] : slice de références de chaînes — permet de passer un tableau de taille variable
// sans allocation. args[0] est le binaire, args[1..] sont les arguments.
fn run(args: &[&str], cwd: &Path) {
    let status = Command::new(args[0])
        .args(&args[1..])       // args[1..] : slice du reste du tableau, sans copie
        .current_dir(cwd)
        .status()
        // unwrap_or_else : comme unwrap mais la valeur de repli est une closure
        // appelée uniquement en cas d'Err (lazy evaluation, contrairement à unwrap_or)
        .unwrap_or_else(|e| panic!("failed to spawn {}: {}", args[0], e));
    // assert! panique avec le message si la condition est fausse
    assert!(status.success(), "command {:?} failed", args);
}

// Générique sur F : n'importe quelle fonction/closure qui prend &str et retourne bool.
// Le compilateur génère une version spécialisée pour chaque type F utilisé (monomorphisation).
fn glob_latest<F: Fn(&str) -> bool>(dir: &Path, predicate: F) -> Option<PathBuf> {
    let mut matches: Vec<PathBuf> = fs::read_dir(dir)
        .ok()?       // ? sur Option : si None (répertoire illisible), retourne None immédiatement
        .filter_map(|e| e.ok())  // DirEntry est lui-même un Result ; on ignore les entrées en erreur
        .map(|e| e.path())
        .filter(|p| p.is_file())
        // and_then chaîne deux Option : si file_name() est Some et to_str() est Some, applique predicate
        .filter(|p| p.file_name().and_then(|n| n.to_str()).map_or(false, &predicate))
        .collect();
    matches.sort();
    // into_iter() consomme le Vec (déplace les éléments) ; last() consomme l'itérateur entier
    matches.into_iter().last()
}

// ── kernel download ───────────────────────────────────────────────────────────

fn download_kernel(versions: &VersionInfo, dest_dir: &Path) -> Result<(), reqwest::Error> {
    fs::create_dir_all(dest_dir).unwrap();

    // None = pas de suffixe requis ; Some(".config") = exclure les fichiers de config kernel
    let kernel_key = resolve_s3_latest_key(&versions.ci_version, &versions.arch, "vmlinux-", None, Some(".config"))?;
    println!("latest kernel key: {}", kernel_key);

    let filename = kernel_key.split('/').last().unwrap();
    let url = format!("https://s3.amazonaws.com/spec.ccfc.min/{}", kernel_key);
    // dest_dir.join() retourne un PathBuf (chemin possédé) ; & le convertit en &Path pour download_file
    download_file(&url, &dest_dir.join(filename))
    // pas de ; final : cette expression est la valeur de retour de la fonction (Result<(), _>)
}

// ── rootfs setup ──────────────────────────────────────────────────────────────

fn setup_rootfs(versions: &VersionInfo, dest_dir: &Path) -> Result<(), reqwest::Error> {
    fs::create_dir_all(dest_dir).unwrap();

    // Some(".squashfs") : on veut uniquement le squashfs, pas les .manifest qui apparaissent aussi dans S3
    let ubuntu_key = resolve_s3_latest_key(&versions.ci_version, &versions.arch, "ubuntu-", Some(".squashfs"), None)?;
    println!("latest ubuntu key: {}", ubuntu_key);

    // Chaîne de strip_prefix / strip_suffix : chacun retourne Option<&str>
    // .unwrap() est justifié car on sait que la clé S3 a ce format (on vient de la filtrer)
    let basename = ubuntu_key.split('/').last().unwrap();
    let ubuntu_version = basename
        .strip_prefix("ubuntu-").unwrap()
        .strip_suffix(".squashfs").unwrap()
        .to_owned(); // &str → String car basename ne vivra pas assez longtemps

    let squashfs_filename = format!("ubuntu-{}.squashfs.upstream", ubuntu_version);
    let url = format!("https://s3.amazonaws.com/spec.ccfc.min/{}", ubuntu_key);
    download_file(&url, &dest_dir.join(&squashfs_filename))?;

    let squashfs_root = dest_dir.join("squashfs-root");
    run(&["sudo", "rm", "-rf", squashfs_root.to_str().unwrap()], dest_dir);
    run(&["unsquashfs", &squashfs_filename], dest_dir);

    let id_rsa = dest_dir.join("id_rsa");
    let id_rsa_pub = dest_dir.join("id_rsa.pub");
    let final_key = dest_dir.join(format!("ubuntu-{}.id_rsa", ubuntu_version));

    // let _ = : on ignore délibérément le Result retourné par remove_file.
    // Si le fichier n'existe pas, ce n'est pas une erreur (rm -f).
    let _ = fs::remove_file(&id_rsa);
    let _ = fs::remove_file(&id_rsa_pub);
    let _ = fs::remove_file(&final_key);

    // -N "" : passphrase vide — la VM peut utiliser la clé sans interaction
    run(&["ssh-keygen", "-f", id_rsa.to_str().unwrap(), "-N", ""], dest_dir);

    let auth_keys_dir = squashfs_root.join("root/.ssh");
    fs::create_dir_all(&auth_keys_dir).unwrap();
    fs::copy(&id_rsa_pub, auth_keys_dir.join("authorized_keys")).unwrap();

    // rename déplace le fichier (inode) sans copie si src et dst sont sur le même FS
    fs::rename(&id_rsa, &final_key).unwrap();

    let overlay = PathBuf::from(REPO_DIR).join("multi-vm-explore/apply-rootfs-overlay.sh");
    run(
        &["sudo", overlay.to_str().unwrap(), squashfs_root.to_str().unwrap()],
        dest_dir,
    );

    // mkfs.ext4 -d requiert que squashfs-root appartienne à root
    run(&["sudo", "chown", "-R", "root:root", squashfs_root.to_str().unwrap()], dest_dir);

    let ext4_path = dest_dir.join(format!("ubuntu-{}.ext4", ubuntu_version));
    // truncate crée un fichier sparse de 1 Go (n'alloue pas vraiment 1 Go sur disque)
    run(&["truncate", "-s", "1G", ext4_path.to_str().unwrap()], dest_dir);
    // -d : peuple l'image depuis le répertoire ; -F : force même si le fichier existe déjà
    run(
        &["sudo", "mkfs.ext4", "-d", squashfs_root.to_str().unwrap(), "-F", ext4_path.to_str().unwrap()],
        dest_dir,
    );

    Ok(())
}

// ── verification ──────────────────────────────────────────────────────────────

fn verify(dest_dir: &Path) {
    println!("\nThe following files were downloaded and set up:");

    // Pattern matching exhaustif sur Option : Some et None sont tous deux traités
    match glob_latest(dest_dir, |n| n.starts_with("vmlinux-")) {
        Some(k) => println!("Kernel: {}", k.display()),
        None => println!("ERROR: no vmlinux-* file found"),
    }

    match glob_latest(dest_dir, |n| n.ends_with(".ext4")) {
        Some(r) => {
            // On redirige stdout/stderr vers /dev/null : on ne veut que le code de retour
            let ok = Command::new("e2fsck")
                .args(["-fn", r.to_str().unwrap()])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                // .map sur Result<ExitStatus> : transforme Ok(status) en Ok(bool), laisse Err intact
                .map(|s| s.success())
                // si status() lui-même a échoué (e2fsck introuvable), on considère le FS invalide
                .unwrap_or(false);
            if ok {
                println!("Rootfs: {}", r.display());
            } else {
                println!("ERROR: {} is not a valid ext4 fs", r.display());
            }
        }
        None => println!("ERROR: no *.ext4 file found"),
    }

    match glob_latest(dest_dir, |n| n.ends_with(".id_rsa")) {
        Some(k) => println!("SSH Key: {}", k.display()),
        None => println!("ERROR: no *.id_rsa key found"),
    }
}

// ── entry point ───────────────────────────────────────────────────────────────

// main retourne Result<(), reqwest::Error> : si une erreur réseau remonte jusqu'ici,
// Rust l'affiche automatiquement et sort avec un code non-zéro.
fn main() -> Result<(), reqwest::Error> {
    let dest_dir = Path::new(BASE_DIR).join("kernel");
    let versions = resolve_versions()?;
    download_kernel(&versions, &dest_dir)?;
    setup_rootfs(&versions, &dest_dir)?;
    verify(&dest_dir);
    Ok(()) // on enveloppe () dans Ok pour satisfaire le type de retour Result
}
