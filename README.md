<img width="2560" height="1345" alt="image" src="https://github.com/user-attachments/assets/1e76eee7-cec7-450e-afe2-bb56165f4bc6" />
### What does it do?

Backup and restore your files. 

**Fedora:**
```bash
sudo dnf install zig gtk4-devel libcurl-devel openssl-devel zlib-devel
```

**Ubuntu/Debian:**
```bash
sudo apt install zig libgtk-4-dev libcurl4-openssl-dev libssl-dev zlib1g-dev
```

Should be straight forward for other linux distros I think. OpenSuse is Zypper etc.
If you have a bug to report, toss it into Issues, please.

**Build:**
```bash
git clone https://github.com/Euclidae/khrowno.git
cd khrowno
zig build
sudo cp zig-out/bin/krowno /usr/local/bin/
```

## Usage

### GUI Mode
```bash
krowno
```

### Create Backup
```bash
# Standard backup with encryption
krowno backup -s standard -o ~/backup.khr -p

# Minimal (configs + keys only)
krowno backup -s minimal -o ~/minimal.khr

# Paranoid (everything + repo snapshots)
krowno backup -s paranoid -o ~/paranoid.khr -p
```

### Restore Backup
```bash
# Restore to current user
krowno restore -i ~/backup.khr -p

# Restore to different user
krowno restore -i ~/backup.khr -u newuser -p

# Restore to specific directory
krowno restore -i ~/backup.khr -o /tmp/restore_test
```

### Other Commands
```bash
# View backup info
krowno info -i ~/backup.khr

# Validate integrity
krowno validate -i ~/backup.khr

# List backups
krowno list -i ~/backups/

# Install Flatpaks only
krowno --install ~/backup.khr
```

## Backup Strategies

### Minimal (~50-600 MB, 1-5 min)
- `.config/`, `.ssh/`, `.gnupg/`
- Package list, Flatpak list

### Standard (~500 MB - 10 GB, 5-20 min) - Recommended
- Everything in Minimal
- `.local/share/`, desktop environment settings
- Browser profiles, package dependencies

### Comprehensive (~10 GB+, 15-30 min)
- Everything in Standard
- `.cache/`, development environments
- Full dependency analysis, all user data

### Paranoid (~10-50 GB, 30-60 min)
- Everything in Comprehensive
- Repository snapshots (exact package versions)
- System-wide configs, all hidden files

Comprehensive is untested. I don't have enough space for it but the file does get rather big. Also couple of unhooked features. Will deal with them
some other time.

### Probable questions
1. Why encrypt backups?
    * some steals the file, they might get your goody goods

2. Why did I make this tool?
    * distro hopping among my favorite distros made easy.
  
3. Will there be updates
    * not for a lil bit. If you want to do something to it... It's MIT license.
4. Why Zig?
   * I like it.
5. Do you love me?
  * yes.
6. Why use it?
  * it works
