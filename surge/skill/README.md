# surge skill（LobeHub 安装源）

本目录是 LUNO Pro 专属技能 `surge` 在 LobeHub 端的安装源。

- `SKILL.md`、`references/`、`scripts/`、`agents/`、`assets/` —— 技能正文与资源
- `surge-skill.zip` —— 打包产物，供 `lh skill install` 使用

## 为什么需要一个 zip

LobeHub 的 `lh skill install` 只支持三种源：GitHub 仓库（下载**整仓** ZIP，技能文件必须在仓库根）、ZIP 文件 URL、marketplace identifier。**没有子目录参数**，所以无法直接把本目录当技能装；而服务端 `downloadRepoZip` 用裸 fetch（**不读任何 GitHub token**），私有仓库与本地路径都走不通，SSRF 防护还会拒绝私有 IP。因此**公网可访问的 ZIP URL 是唯一入口**。

## 重新打包

```sh
python3 - <<'PY'
import zipfile, os
root = 'surge/skill'
out = os.path.join(root, 'surge-skill.zip')
files = [os.path.join(dp, fn) for dp, _, fns in os.walk(root) for fn in fns]
files = [p for p in files if os.path.abspath(p) != os.path.abspath(out)]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(files):
        z.write(p, os.path.relpath(p, root))
PY
```

## 安装 / 更新

```sh
lh skill install https://raw.githubusercontent.com/LucaLin233/Proxy/main/surge/skill/surge-skill.zip
```

两个注意点：install 是**新建**记录，同名技能须先 `lh skill delete <id> --yes`；平台会按下载 URL 生成 identifier，不可自定义。
