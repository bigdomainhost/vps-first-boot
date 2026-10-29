# vps-first-boot

One bash script for the first ten minutes on a fresh Debian or Ubuntu VPS. It does the boring hardening that everyone means to do and half of us skip:

- creates a normal user with sudo, logging in with your SSH public key
- turns on `ufw` and allows SSH, 80 and 443, nothing else inbound
- installs `fail2ban` with an sshd jail (5 failures in 10 minutes gets a 1 hour ban)
- installs `unattended-upgrades` and switches on daily security updates
- optionally adds a swap file sized from RAM
- optionally sets the timezone to Asia/Kolkata
- last of all, turns off root login and password login over SSH, but only after you confirm the new user can actually log in

It prints every change it makes, and a summary at the end. Run it twice and the second run should report that nothing changed.

We wrote this at [Bigdomainhost](https://bigdomainhost.com/vps-hosting.html) because "create a non-root user, move SSH to key-only, enable the firewall" is the first job on every new VPS, and the easiest one to get wrong. It has nothing specific to our platform in it, so it should work on any KVM VPS running the distros below.

## Intended for

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12

Those are the distros it was written against. On anything else it refuses to run unless you pass `--force`. It needs `apt` and systemd, so RHEL-family systems (AlmaLinux, Rocky) are out of scope.

## Usage

Read it before you run it. It is one file, about 500 lines with comments, and it is going to change how you log in to your server. Piping a stranger's script into a root shell is a bad habit even when the stranger is us.

```sh
curl -fsSLO https://raw.githubusercontent.com/bigdomainhost/vps-first-boot/main/first-boot.sh
less first-boot.sh
sudo bash first-boot.sh --user deploy --key "ssh-ed25519 AAAAC3Nza... you@laptop"
```

Your public key is the one line in `~/.ssh/id_ed25519.pub` on your own machine. If you do not have one yet:

```sh
ssh-keygen -t ed25519 -C "you@yourcompany.in"
cat ~/.ssh/id_ed25519.pub
```

If you already log in as root with a key (we let you paste one at order time, and so do most providers), you can point `--key` at root's file and it will take the first key it finds:

```sh
sudo bash first-boot.sh --user deploy --key /root/.ssh/authorized_keys --swap --ist
```

If you really want the one-liner, it works, because the confirmation prompt reads from your terminal and not from the pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/bigdomainhost/vps-first-boot/main/first-boot.sh \
  | sudo bash -s -- --user deploy --key "ssh-ed25519 AAAA... you@laptop"
```

### The SSH safety check

Locking yourself out is the classic first-day mistake, so the SSH part runs last and is careful:

1. Before touching sshd, it checks that sshd reads `~/.ssh/authorized_keys`, has public key auth on, has no `AllowUsers`/`AllowGroups` rule that would block the new user, and that the key file has the right owner and mode.
2. It cannot test the key itself, because the private key is on your laptop, not on the server. So it stops and asks you to open a second terminal, run `ssh deploy@your-ip` and `sudo true`, and type `yes` only if both worked.
3. It then writes `/etc/ssh/sshd_config.d/01-first-boot.conf`, runs `sshd -t`, and deletes the file again if sshd rejects it. Your current session stays open throughout.
4. After the reload it reads back the effective config with `sshd -T` and warns you if some other file is overriding it.

If there is no terminal to ask on (cloud-init, a CI job), it skips this step and tells you. Test the login yourself, then re-run with `--yes`.

If you do lock yourself out anyway, use your provider's out-of-band console. On ours it is in the control panel, see the [docs](https://bigdomainhost.com/docs.html).

## Flags

| Flag | What it does |
|---|---|
| `-u`, `--user NAME` | Required. User to create, or reuse if it exists, and add to `sudo`. |
| `-k`, `--key KEY` | Required. The public key text, or a path to a `.pub` or `authorized_keys` file. |
| `--swap` | Create `/swapfile`: 1 GB if RAM is under 2 GB, otherwise 2 GB. Sets `vm.swappiness = 10`. |
| `--swap-size MB` | Same, with the size you choose. |
| `--ist` | Set the timezone to Asia/Kolkata. |
| `-y`, `--yes` | Do not ask before switching SSH to key-only. Use only after testing the login yourself. |
| `--skip-ssh-lockdown` | Do everything except the sshd change. |
| `--force` | Run on a distro not listed above. |
| `-h`, `--help` | Help. |

## Files it writes

- `/etc/sudoers.d/90-first-boot-<user>`
- `/etc/ssh/sshd_config.d/01-first-boot.conf`
- `/etc/fail2ban/jail.d/first-boot.local`
- `/etc/apt/apt.conf.d/20auto-upgrades`
- `/swapfile`, a line in `/etc/fstab` and `/etc/sysctl.d/90-first-boot-swap.conf` (only with `--swap`)

Everything else is plain `useradd`, `ufw allow`, `apt-get install` and `timedatectl`.

## Choices you may disagree with

**Passwordless sudo.** The new user has no password, so sudo has to be `NOPASSWD`, the same as the default `ubuntu` user on most cloud images. If you want a password on sudo:

```sh
sudo passwd deploy
sudo rm /etc/sudoers.d/90-first-boot-deploy
```

**SSH stays on port 22.** Moving it cuts log noise but does not stop anyone who is actually looking, and fail2ban handles the noise. On Ubuntu 24.04 changing the port also means editing `ssh.socket`, which is a good way to lock yourself out.

**Swap is 1 to 2 GB, not "2x RAM".** Swap on a VPS is an emergency buffer that turns an out-of-memory crash into a slow patch. If the server swaps every day, it needs more RAM. There is a longer write-up on this in our [guide to VPS RAM sizing](https://bigdomainhost.com/guide-how-much-ram-does-a-vps-need.html).

**No automatic reboots.** Unattended-upgrades installs security updates but will not reboot for a new kernel. Check `/var/run/reboot-required` now and then.

## Things it does not do

- **Docker bypasses ufw.** Ports published with `docker run -p` go straight through iptables and ufw never sees them. If you run Docker, bind to `127.0.0.1` and put a reverse proxy in front, or read up on `DOCKER-USER` rules.
- **Provider firewalls are separate.** Many providers have a network firewall in front of the VPS as well. On ours the default is deny-inbound except SSH on port 22, so you also need to open 80 and 443 there before a website will load. ufw on the box does not change that.
- No web server, database, or kernel `sysctl` tuning. That depends on what you are running, and a first-boot script should not guess.

## Contributing

Bug reports and pull requests are welcome, especially from anyone running it on a setup we have not. Please include the distro, the exact command and the full output.

## Licence

MIT. See [LICENSE](LICENSE).
