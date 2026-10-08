#!/bin/bash
# 一键设置（macOS）：双击运行。若双击提示无法打开，在终端执行：bash 一键设置.command
cd "$(dirname "$0")" || exit 1
bash ./setup-proxy.sh "$@"
echo
read -r -p "完成，按回车键关闭窗口 " _
