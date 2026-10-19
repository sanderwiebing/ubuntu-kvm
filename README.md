# Ubuntu 24.04 QEMU VM

Ubuntu 24.04 (noble) VMs for kernel work. Root SSH with a key, shared folder at
`/mnt/shared`, and you can boot either your own kernel or the Ubuntu kernel
installed in the image.

Setup, once: `sudo usermod -aG kvm $USER`, then log out and back in.

## 1. Create the image

```bash
sudo ./create-image.sh -k 6.8.0-71-generic       # optional: -s 64G (sparse), -p "pkg1,pkg2"
```

Creates `noble.img` (the base image) and the SSH key `noble.id_ed25519`.
`-k` installs that kernel and its modules into the image. You can repeat it.

## 2. Add a new kernel

Download the kernel, plus its debug symbols and, optionally, the source:

```bash
./download-kernel.sh 6.8.0-71 --src              # -> 6.8.0-71-generic/{vmlinuz,vmlinux-dbg,config,src}
```

Install the same kernel inside a VM (see 3), so its modules (9p etc.) are there:

```bash
apt install linux-image-6.8.0-71-generic linux-modules-6.8.0-71-generic   # inside the VM
poweroff
```

You can also pass `-k 6.8.0-71-generic` when creating the image in step 1.

## 3. Create a new VM

```bash
./vm.sh new a          # fresh VM on top of noble.img
./vm.sh fork a b       # copy of a's current state (a must be stopped)
./vm.sh ls             # list VMs and their ssh ports
./vm.sh rm b           # delete
```

Each VM lives in `vms/NAME/` and has its own disk (a small qcow2 overlay),
SSH port and `shared/` folder. Never rebuild or write to `noble.img` while VMs
use it. To make a new base, use `create-image.sh -o noble-2.img` and
`vm.sh new NAME -b noble-2.img`.

## 4. Launch it

```bash
./run-vm.sh -n a --distro                        # Ubuntu kernel installed in the VM (newest)
./run-vm.sh -n a --distro=6.8.0-71-generic       # a specific installed kernel
./run-vm.sh -n a 6.8.0-71-generic/vmlinuz        # your own bzImage
./ssh-vm.sh -n a                                 # from another terminal
```

Quit the VM with `Ctrl-a x`, or run `poweroff` inside it.

Useful options:

| Option | Effect |
| --- | --- |
| `-g` | gdb stub on `:1234` with `nokaslr`. Attach with `gdb 6.8.0-71-generic/vmlinux-dbg -ex 'target remote :1234'` |
| `--snapshot` | Throw away all disk changes on exit |
| `--global-shared` | Share `./shared` instead of `vms/NAME/shared` |
| `-m 8G`, `-c 4` | Memory and number of CPUs |
| `-t 4` | Pin QEMU to host CPU 4 |

Without `-n`, `run-vm.sh` boots the base image itself (port 7777, `./shared`).
Use `--snapshot` for that once VMs depend on it.
