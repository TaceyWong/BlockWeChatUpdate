# Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber

Invoke-PS2EXE `
    -inputFile "block-wechat-update.ps1" `
    -outputFile "BlockWeChatUpdate.exe" `
    -iconFile "logo.ico" `
    -noConsole `
    -requireAdmin `
    -DPIAware `
    -title "微信更新屏蔽工具" `
    -description "屏蔽PC微信WeChatUpdate自动更新" `
    -product "BlockWeChatUpdate" `
    -version "1.0.0.0" `
    -copyright "Copyright © 2026 TaceyWong@白昼寻星工作室"
