#!/bin/bash
# 同事一键配置（macOS）：双击运行。若双击提示无法打开或没有权限，在终端执行：bash setup-nodes.command
cd "$(dirname "$0")" || exit 1
bash ./setup-nodes.sh "$@"
echo
read -r -p "完成，按回车键关闭窗口 " _
