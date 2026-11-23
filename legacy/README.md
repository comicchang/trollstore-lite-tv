# legacy —— 早期 v1 产物（已废弃）

这里的文件属于最初那版「设备端 install.sh + manifest 清单」的实现，
在 2026-11-23 09:5x 之后已被 `almatrust` + `almatrustd` + `dist/*.deb` 取代：

- `install.sh` / `install_v2.sh` / `alma-tvos-install.sh` —— 早期安装脚本，功能并入 `almatrust install`
- `trustlib.sh` / manifest 清单 —— 早期信任重放，已由 `installed.tsv` + `almatrust trust retrust` 取代
- `ent_nt3.plist` —— 当时验证 `get-task-allow` 用的测试 entitlement
- `VERIFICATION.md` —— 当时的验收记录

保留仅为考古，不要再使用。
