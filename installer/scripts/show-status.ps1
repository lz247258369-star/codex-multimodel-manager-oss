. (Join-Path $PSScriptRoot "_common.ps1")
$codexHome = Get-CodexHome
$config = Join-Path $codexHome "config.toml"
$state = Load-State

Write-Host ""
Write-Host "Codex Multi-Model 状态" -ForegroundColor Cyan
Write-Host "CODEX_HOME: $codexHome"
Write-Host "config.toml: $(if (Test-Path $config) {'存在'} else {'不存在'})"
Write-Host "Skill: $(if (Test-Path (Join-Path $codexHome 'skills\codex-multimodel-manager\SKILL.md')) {'已安装'} else {'未安装'})"
Write-Host ""
Write-Host "Provider（只显示是否配置，不显示 Key）：" -ForegroundColor Cyan

$items = @(
    @("OpenAI ChatGPT","always"),
    @("OpenAI API","openai_api_enabled","CODEX_OPENAI_API_KEY"),
    @("MiMo","mimo_enabled","MIMO_API_KEY"),
    @("Alibaba Model Studio","aliyun_enabled","CODEX_DASHSCOPE_API_KEY"),
    @("xAI","xai_enabled","XAI_API_KEY"),
    @("Groq","groq_enabled","GROQ_API_KEY"),
    @("OpenRouter","openrouter_enabled","OPENROUTER_API_KEY")
)

foreach ($i in $items) {
    if ($i[1] -eq "always") {
        Write-Host (" - {0}: profile 已提供（使用现有 ChatGPT 登录）" -f $i[0])
        continue
    }
    $enabled = Get-StateValue $state $i[1] $false
    $envVal = [Environment]::GetEnvironmentVariable($i[2], [EnvironmentVariableTarget]::User)
    $keyState = if ([string]::IsNullOrWhiteSpace($envVal)) { "Key未设置" } else { "Key已设置" }
    Write-Host (" - {0}: {1}; {2}" -f $i[0], $(if ($enabled) {"已配置"} else {"未配置"}), $keyState)
}
Write-Host ""
Write-Host "安全说明：不会显示 API Key 值。" -ForegroundColor DarkGray
