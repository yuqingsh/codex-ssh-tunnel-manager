#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PublicKeyPath = (Join-Path $HOME '.ssh\id_ed25519_codex_devbox.pub'),

    [string[]]$Aliases = @('primary-dev', 'secondary-dev')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
    throw "Public key file was not found: $PublicKeyPath"
}
if ([IO.Path]::GetExtension($PublicKeyPath) -ne '.pub') {
    throw 'PublicKeyPath must point to a .pub file. Never pass a private key.'
}

$publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
if ($publicKey -notmatch '^(ssh-(ed25519|rsa)|ecdsa-|sk-)') {
    throw 'The selected file does not look like an OpenSSH public key.'
}

$remoteCommand = 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; cat >> ~/.ssh/authorized_keys; sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'

Write-Warning 'Verify each server host-key fingerprint through a trusted channel before accepting it.'
foreach ($alias in $Aliases) {
    if ($alias -notmatch '^[A-Za-z0-9._-]+$') {
        throw "SSH alias '$alias' contains unsupported characters."
    }

    Write-Host "Installing public key on $alias ..." -ForegroundColor Cyan
    $publicKey | & ssh.exe $alias $remoteCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Public-key installation failed on $alias with exit code $LASTEXITCODE."
    }

    $hostname = & ssh.exe -o BatchMode=yes -o ConnectTimeout=10 $alias 'hostname'
    if ($LASTEXITCODE -ne 0) {
        throw "Key-only verification failed on $alias."
    }
    Write-Host "$alias is ready (remote hostname: $hostname)." -ForegroundColor Green
}
