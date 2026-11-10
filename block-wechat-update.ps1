<#
微信 PC 屏蔽更新 GUI
- 自动查找 WeChatUpdate.exe / WeixinUpdate.exe
- 对 Users 拒绝读执行+写入+删除，降低被覆盖重生概率
- 状态检测按 SID/账户名识别 Deny
- 解除时重置显式 ACL（含历史误加的 SYSTEM/Administrators Deny）
- 历史版本下载链接（浏览器打开）
#>
#Requires -RunAsAdministrator
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$ErrorActionPreference = 'Continue'
$UsersSid = 'S-1-5-32-545'
$HistoryRepoUrl = 'https://github.com/cscnk52/wechat-windows-versions/releases'
$HistoryApiUrl = 'https://api.github.com/repos/cscnk52/wechat-windows-versions/releases?per_page=20'

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="微信更新屏蔽工具" Width="680" Height="560" WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="160"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0 0 0 12">
            <Button x:Name="btnCheck" Content="检测状态" Width="110" Height="36" Margin="0 0 10 0"/>
            <Button x:Name="btnBlock" Content="屏蔽更新" Width="110" Height="36" Margin="0 0 10 0"/>
            <Button x:Name="btnUnblock" Content="解除屏蔽" Width="110" Height="36"/>
        </StackPanel>
        <TextBlock x:Name="tbStatus" Grid.Row="1" Margin="0 0 0 10" FontSize="12" Foreground="#222" TextWrapping="Wrap"/>
        <DockPanel Grid.Row="2" Margin="0 0 0 6" LastChildFill="False">
            <TextBlock DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="#666" Margin="0 0 12 0">历史版本下载：</TextBlock>
            <Button x:Name="btnRefreshHistory" DockPanel.Dock="Left" Content="刷新列表" Width="88" Height="28" Margin="0 0 8 0"/>
            <Button x:Name="btnOpenArchive" DockPanel.Dock="Left" Content="打开仓库全部版本" Width="140" Height="28"/>
        </DockPanel>
        <ListBox x:Name="lstHistory" Grid.Row="3" Margin="0 0 0 10" FontFamily="Consolas" FontSize="12"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
        <TextBlock Grid.Row="4" Margin="0 0 0 6" Foreground="#666">运行日志：</TextBlock>
        <TextBox x:Name="txtLog" Grid.Row="5" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11"/>
    </Grid>
</Window>
'@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$win = [System.Windows.Markup.XamlReader]::Load($reader)

$btnCheck           = $win.FindName('btnCheck')
$btnBlock           = $win.FindName('btnBlock')
$btnUnblock         = $win.FindName('btnUnblock')
$btnRefreshHistory  = $win.FindName('btnRefreshHistory')
$btnOpenArchive     = $win.FindName('btnOpenArchive')
$lstHistory         = $win.FindName('lstHistory')
$tbStatus           = $win.FindName('tbStatus')
$txtLog             = $win.FindName('txtLog')

function Write-Log([string]$msg) {
    $txtLog.AppendText("[$(Get-Date -Format HH:mm:ss)] $msg`r`n")
    $txtLog.ScrollToEnd()
}

function Open-InBrowser([string]$url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return }
    Start-Process $url | Out-Null
    Write-Log ("已在浏览器打开：{0}" -f $url)
}

function Get-IdentitySid([System.Security.Principal.IdentityReference]$identity) {
    try {
        return $identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $identity.Value
    }
}

function Test-UsersExecuteDenied([string]$path) {
    $acl = Get-Acl -LiteralPath $path
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne 'Deny') { continue }
        $sid = Get-IdentitySid $ace.IdentityReference
        $name = $ace.IdentityReference.Value
        $isUsers = ($sid -eq $UsersSid) -or ($name -eq 'BUILTIN\Users') -or ($name -eq 'Users')
        if (-not $isUsers) { continue }
        $rights = $ace.FileSystemRights.ToString()
        if ($rights -match 'ReadAndExecute|ExecuteFile|ReadData|FullControl|Modify') {
            return $true
        }
    }
    return $false
}

function Find-UpdaterPaths {
    $fixed = @(
        'C:\ProgramData\Tencent\WeChat\WeChatUpdate.exe',
        "$env:LOCALAPPDATA\Tencent\WeChat\WeChatUpdate.exe",
        'C:\Program Files\Tencent\WeChat\WeChatUpdate.exe',
        'C:\Program Files (x86)\Tencent\WeChat\WeChatUpdate.exe'
    )

    $roots = @(
        'C:\ProgramData\Tencent',
        'C:\Program Files\Tencent',
        'C:\Program Files (x86)\Tencent',
        "$env:LOCALAPPDATA\Tencent",
        "$env:APPDATA\Tencent"
    )

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($p in $fixed) {
        if (Test-Path -LiteralPath $p) { [void]$found.Add($p) }
    }

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(WeChatUpdate|WeixinUpdate)\.exe$' } |
            ForEach-Object { [void]$found.Add($_.FullName) }
    }

    return @($found | Select-Object -Unique)
}

function Clear-WeChatUpdateTasks {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -match 'WeChatUpdate|WeixinUpdate' -or
        ($_.TaskPath -match '\\Tencent\\' -and $_.TaskName -match 'WeChat|Weixin|Update')
    }
    if (-not $tasks) {
        Write-Log '未发现相关计划任务'
        return
    }
    foreach ($t in @($tasks)) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log ("已删除计划任务：{0}{1}" -f $t.TaskPath, $t.TaskName)
        } catch {
            Write-Log ("删除计划任务失败：{0}{1} -> {2}" -f $t.TaskPath, $t.TaskName, $_.Exception.Message)
        }
    }
}

function Test-BlockState {
    $paths = Find-UpdaterPaths
    $existCount = $paths.Count
    $blockedCount = 0
    foreach ($p in $paths) {
        if (Test-UsersExecuteDenied $p) { $blockedCount++ }
    }

    if ($existCount -eq 0) {
        $tbStatus.Text = '未找到 WeChatUpdate.exe / WeixinUpdate.exe'
        $tbStatus.Foreground = '#ff8800'
    } elseif ($blockedCount -ge $existCount) {
        $tbStatus.Text = ("已屏蔽更新（{0}/{1}）" -f $blockedCount, $existCount)
        $tbStatus.Foreground = '#009933'
    } elseif ($blockedCount -gt 0) {
        $tbStatus.Text = ("部分未屏蔽（{0}/{1}）" -f $blockedCount, $existCount)
        $tbStatus.Foreground = '#cc2222'
    } else {
        $tbStatus.Text = ("未屏蔽（找到 {0} 个更新程序）" -f $existCount)
        $tbStatus.Foreground = '#cc2222'
    }

    Write-Log ("状态检测：找到 {0} 个更新程序，已锁定 {1} 个" -f $existCount, $blockedCount)
    foreach ($p in $paths) {
        $flag = if (Test-UsersExecuteDenied $p) { '已锁定' } else { '未锁定' }
        Write-Log ("  [{0}] {1}" -f $flag, $p)
    }
}

function Lock-Updater([string]$path) {
    $denyArg = '*{0}:(RX,W,D)' -f $UsersSid
    $out = & icacls $path /deny $denyArg 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("icacls deny 失败：{0}" -f ($out | Out-String).Trim())
    }
}

function Unlock-Updater([string]$path) {
    $out = & icacls $path /reset 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out2 = & icacls $path /remove:d ('*{0}' -f $UsersSid) 2>&1
        $out3 = & icacls $path /remove:d 'Users' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("icacls reset/remove 失败：{0} | {1} | {2}" -f `
                (($out | Out-String).Trim()), `
                (($out2 | Out-String).Trim()), `
                (($out3 | Out-String).Trim()))
        }
    }
}

function New-HistoryItem([string]$title, [string]$url, [string]$hint) {
    $panel = New-Object System.Windows.Controls.DockPanel
    $panel.LastChildFill = $true
    $panel.Margin = New-Object System.Windows.Thickness(2, 2, 2, 2)

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = '浏览器打开'
    $btn.Width = 88
    $btn.Height = 26
    $btn.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    $btn.Tag = $url
    [System.Windows.Controls.DockPanel]::SetDock($btn, [System.Windows.Controls.Dock]::Right)
    $btn.Add_Click({
        param($sender, $e)
        Open-InBrowser ([string]$sender.Tag)
    })

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = if ($hint) { "$title  ·  $hint" } else { $title }
    $tb.VerticalAlignment = 'Center'
    $tb.TextWrapping = 'NoWrap'
    $tb.ToolTip = $url

    [void]$panel.Children.Add($btn)
    [void]$panel.Children.Add($tb)

    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = $panel
    $item.Tag = $url
    $item.Padding = New-Object System.Windows.Thickness(4, 2, 4, 2)
    return $item
}

function Set-FallbackHistory {
    $lstHistory.Items.Clear()
    $fallback = @(
        @{ Title = 'v4.1.15.56'; Url = 'https://github.com/cscnk52/wechat-windows-versions/releases/tag/v4.1.15.56'; Hint = '离线备用' },
        @{ Title = 'v4.1.15.50'; Url = 'https://github.com/cscnk52/wechat-windows-versions/releases/tag/v4.1.15.50'; Hint = '离线备用' },
        @{ Title = 'v4.1.15.13'; Url = 'https://github.com/cscnk52/wechat-windows-versions/releases/tag/v4.1.15.13'; Hint = '离线备用' },
        @{ Title = '全部版本列表'; Url = $HistoryRepoUrl; Hint = 'GitHub Releases' }
    )
    foreach ($row in $fallback) {
        [void]$lstHistory.Items.Add((New-HistoryItem $row.Title $row.Url $row.Hint))
    }
}

function Update-HistoryList {
    Write-Log '正在拉取历史版本列表…'
    $lstHistory.Items.Clear()
    try {
        $headers = @{
            'User-Agent' = 'ReShape-Custom-WeChat-Block'
            'Accept'     = 'application/vnd.github+json'
        }
        $releases = Invoke-RestMethod -Uri $HistoryApiUrl -Headers $headers -TimeoutSec 20
        if (-not $releases) { throw '接口返回为空' }

        $count = 0
        foreach ($rel in @($releases)) {
            $asset = @($rel.assets | Where-Object { $_.name -match '\.exe$' } | Select-Object -First 1)
            $url = if ($asset -and $asset.browser_download_url) {
                [string]$asset.browser_download_url
            } else {
                [string]$rel.html_url
            }
            $hint = if ($asset -and $asset.name) { [string]$asset.name } else { '发布页' }
            $title = if ($rel.tag_name) { [string]$rel.tag_name } else { [string]$rel.name }
            [void]$lstHistory.Items.Add((New-HistoryItem $title $url $hint))
            $count++
        }

        [void]$lstHistory.Items.Add((New-HistoryItem '打开全部版本' $HistoryRepoUrl 'GitHub Releases'))
        Write-Log ("历史版本已加载 {0} 条（点击右侧按钮用浏览器打开）" -f $count)
    } catch {
        Write-Log ("拉取失败，使用备用链接：{0}" -f $_.Exception.Message)
        Set-FallbackHistory
    }
}

$win.Add_Loaded({
    Test-BlockState
    Update-HistoryList
})

$btnCheck.Add_Click({
    Write-Log '===== 手动检测状态 ====='
    Test-BlockState
})

$btnRefreshHistory.Add_Click({ Update-HistoryList })
$btnOpenArchive.Add_Click({ Open-InBrowser $HistoryRepoUrl })

$lstHistory.Add_MouseDoubleClick({
    $item = $lstHistory.SelectedItem
    if ($item -and $item.Tag) {
        Open-InBrowser ([string]$item.Tag)
    }
})

$btnBlock.Add_Click({
    Write-Log '===== 开始屏蔽 ====='
    Get-Process -Name WeChatUpdate, WeixinUpdate -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log '已尝试终止 WeChatUpdate / WeixinUpdate'

    $paths = Find-UpdaterPaths
    if ($paths.Count -eq 0) {
        Write-Log '未找到任何更新程序，无法屏蔽'
        Test-BlockState
        return
    }

    foreach ($p in $paths) {
        try {
            Lock-Updater $p
            Write-Log ("锁定成功：{0}" -f $p)
        } catch {
            Write-Log ("锁定失败：{0} -> {1}" -f $p, $_.Exception.Message)
        }
    }

    Clear-WeChatUpdateTasks
    Write-Log '===== 屏蔽完成（微信升级后仍可能重新放出更新器，需再点一次屏蔽） ====='
    Test-BlockState
})

$btnUnblock.Add_Click({
    Write-Log '===== 开始解除屏蔽 ====='
    $paths = Find-UpdaterPaths
    if ($paths.Count -eq 0) {
        Write-Log '未找到任何更新程序'
        Test-BlockState
        return
    }

    foreach ($p in $paths) {
        try {
            Unlock-Updater $p
            Write-Log ("已恢复权限：{0}" -f $p)
        } catch {
            Write-Log ("恢复失败：{0} -> {1}" -f $p, $_.Exception.Message)
        }
    }

    Write-Log '===== 解除完成 ====='
    Test-BlockState
})

$win.ShowDialog() | Out-Null
