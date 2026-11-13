# AGENTS.md

> 本文件是该项目的 AI 协作规则，优先级高于 ai-workspace 中的通用规则。

## 项目概览

- 名称：toolbox
- 用途：个人运维工具箱，存放服务器脚本与 Clash/OpenClash 订阅转换配置、规则集
- 技术栈：Bash / POSIX sh；Clash 配置（subconverter INI、YAML、`.list` 规则集）；无构建流程、无依赖

## 常用命令

```bash
# install / dev：无，脚本与配置直接使用
# 语法检查（改完脚本必跑）
bash -n shell/<script>.sh
# 静态检查（本机装了 shellcheck 时）
shellcheck shell/<script>.sh
# 实机验证：在一次性容器里跑，不要在自己的机器上直接执行
docker run --rm -it -v "$PWD/shell:/s:ro" debian:12 bash /s/<script>.sh --help
```

没有自动化测试。YAML / INI / 规则集没有校验命令，改动后人工核对格式。

## 目录结构

- `shell/`：服务器脚本，彼此独立、单文件可运行
  - `init.sh`：Linux 服务器初始化（SSH、时区、DNS、BBR、换源、Docker），用法见 `--help`
  - `goedge-node.sh`：GoEdge 边缘节点部署
  - `ols-install.sh`、`lsup.sh`：OpenLiteSpeed 安装与升级
- `clash/config/`：订阅转换模板 `cee.ini`、DNS 基础配置 `dns-base.yaml`
- `clash/ruleset/`：自维护规则集（`.list`）
- `custom_proxy.txt`：强制代理域名列表

## 规则

- 动手前先确认上述命令可运行；不确定时先问。
- 小步修改，每步后运行相关验证。
- 遵循现有代码风格；新增依赖需说明理由。
- 不修改与任务无关的文件；不改项目目录外的文件。
- 不输出、不提交任何密钥或真实 `.env` 内容；所需变量见 `.env.example`。
- push、发布、数据迁移、删除数据等操作需先确认。

## 完成时

输出交接：当前分支、完成/未完成内容、下一步、验证命令、风险/阻塞项。

## 项目特有约定

- 默认分支是 `master`（不是 `main`）。
- `clash/` 下的文件通过 `raw.githubusercontent.com/ceeim/toolbox/master/...` 被线上订阅转换和 OpenClash 直接引用：推送到 `master` 即发布，移动或重命名文件会让已有订阅失效，需先确认。
- 脚本会以 root 身份在真实服务器上运行：改动 SSH、防火墙、网络相关逻辑时要保证失败可回退，不能把人锁在机器外。
- 脚本中不写死任何服务器地址、账号、密码、Token，一律通过参数或交互输入传入。
- 脚本的提示与日志面向使用者，用简体中文；注释用简体中文；标识符与参数名用英文。
- 新脚本用 `#!/usr/bin/env bash` 加 `set -euo pipefail`，需兼容 Debian / Ubuntu / RHEL 系；`lsup.sh` 来自 OpenLiteSpeed 上游，保持原样不做风格整理。
