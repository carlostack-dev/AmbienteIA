# AmbienteIA — Central de Controle

Gerenciador de ambiente local de agentes de IA para Windows 11

**Versão:** v0.1.0
**Tecnologia:** PowerShell 5.1 + WPF/XAML
**Status:** Funcional, pronto para uso

---

## 1. Visão Geral

O AmbienteIA é uma aplicação desktop (PowerShell + WPF) para gerenciar o ambiente local de agentes de IA no Windows 11. Ele inicia, monitora e controla:

- **Headroom** (proxy de contexto, porta 8787)
- **Hermes Agent** (CLI, diretório de trabalho configurável)
- **NVIDIA NIM** (conectividade via `NVIDIA_BASE_URL`)

O modelo padrão é mantido: `nvidia/nemotron-3.5-super-vl-120b-a12b`.

A interface é moderna, escura, com detalhes roxos, cartões de status, indicadores de conexão, métricas de requisições/tokens/latência, histórico de atividades e diagnóstico completo somente leitura.

---

## 2. Estrutura de Pastas

```
AmbienteIA/
├── Iniciar-AmbienteIA.bat       # Inicializador (duplo clique)
├── Iniciar-AmbienteIA.ps1       # Janela WPF principal
├── Diagnostico.ps1              # Diagnóstico somente leitura (console)
├── config.yaml.example          # Template de configuração do Hermes
├── .env.example                 # Template de variáveis de ambiente
├── .gitignore                   # Arquivos ignorados pelo Git
├── README.md                    # Este arquivo
├── LICENSE                      # Licença MIT (incluída)
├── Core/
│   └── Ambiente-IA.Core.ps1     # Lógica compartilhada (healthchecks, início, diagnóstico, stats)
├── Interface/
│   └── Interface.xaml           # Layout WPF (tema escuro, roxo)
├── Logic/
│   └── Main-Logic.ps1           # Cópia de referência da janela principal
├── Monitoramento/
│   └── Monitor.ps1              # Monitor de estatísticas do Headroom (console)
├── ProcessManagement/
│   └── Process-Manager.ps1      # Gerenciamento de processos (listar/parar)
├── Assets/
│   ├── hermes.png
│   ├── headroom.png
│   └── nvidia.png
├── Logs/                        # Criado automaticamente (ignorado pelo Git)
└── Backup/                      # Cópia de segurança do projeto anterior (ignorado pelo Git)
```

---

## 3. Arquivos do Repositório (v0.1.0)

| Arquivo | Função |
|---|---|
| `Iniciar-AmbienteIA.bat` | Inicializador duplo-clique, abre a WPF sem terminal persistente |
| `Iniciar-AmbienteIA.ps1` | Janela principal com todos os controles e eventos |
| `Diagnostico.ps1` | Diagnóstico completo somente leitura no console |
| `Core/Ambiente-IA.Core.ps1` | Lógica compartilhada: detecção, inicialização, diagnóstico, estatísticas |
| `Interface/Interface.xaml` | Layout WPF: tema escuro, detalhes roxos, cartões, métricas, logs |
| `Logic/Main-Logic.ps1` | Cópia de referência da janela principal |
| `Monitoramento/Monitor.ps1` | Monitor de estatísticas do Headroom (uso independente) |
| `ProcessManagement/Process-Manager.ps1` | Lista e encerra processos gerenciados pelo AmbienteIA |
| `Assets/*.png` | Ícones da interface |
| `config.yaml.example` | Template de configuração do Hermes (não é o real) |
| `.env.example` | Template de variáveis de ambiente (não é o real) |
| `.gitignore` | Arquivos e pastas ignorados pelo Git |

---

## 4. Funcionalidades

### Botões (11 no total)

1. **INICIAR AMBIENTE** — Verifica Headroom, inicia o proxy se necessário, carrega `NVIDIA_API_KEY` do `.env` sem exibi-la, valida `/livez`, configura `NVIDIA_BASE_URL`, abre o Hermes, evita processos duplicados.
2. **PARAR** — Encerra apenas processos iniciados pelo AmbienteIA (rastreados por PID).
3. **ABRIR HERMES** — Abre o Hermes no diretório de trabalho (habilitado com Headroom ONLINE).
4. **ABRIR PASTA DE PROJETOS** — Abre o diretório de projetos no Explorer.
5. **DIAGNÓSTICO** — Executa diagnóstico completo somente leitura.
6. **TESTAR NVIDIA** — Testa conectividade com o endpoint NVIDIA NIM.
7. **TESTAR HEADROOM** — Teste pontual do Headroom (`/livez`, `/readyz`, upstream).
8. **ATUALIZAR ESTATS** — Força atualização das estatísticas do `/stats`.
9. **LOGS** — Abre a pasta de logs no Explorer.
10. **CONFIG HERMES** — Abre `config.yaml` do Hermes no Bloco de Notas.
11. **ENCERRAR INTERFACE** — Fecha a interface e encerra os serviços do AmbienteIA (Headroom e Hermes), evitando processos órfãos.

### Monitoramento

- Atualização a cada ~2,5 segundos sem travar a interface.
- Chamadas assíncronas para testes e processos demorados.
- Estatísticas reais do Headroom via `/stats`: requisições, tokens economizados, latência média, erros.

### Diagnóstico

Classificação: **OK / AVISO / ERRO / NÃO TESTADO**.

Verifica:
- Windows e arquitetura
- Python e versão
- Instalação e versão do Headroom (0.44.0)
- Instalação do Hermes
- Arquivos de configuração (`config.yaml`, `.env`)
- Disponibilidade da porta 8787
- Estado do proxy (`/livez`, `/readyz`, upstream)
- Conectividade com NVIDIA NIM
- Modelo configurado
- Erros recentes
- Permissões e diretórios necessários

Não altera configurações automaticamente.

---

## 4.1. Melhorias recentes (versão em preparação)

- **Encerramento seguro da interface**: ao fechar a janela (botão ENCERRAR INTERFACE ou `X`), o AmbienteIA encerra os serviços que iniciou (Headroom e Hermes), evitando processos órfãos. Antes, os serviços ficavam rodando em segundo plano.
- **Gerenciamento robusto de processos**: rastreamento de PIDs compartilhado entre runspaces, encerramento ordenado (CloseMainWindow → espera → Kill), detecção de processos filhos via WMI e camada adicional por título de janela.
- **Carregamento de credenciais do .env**: `NVIDIA_API_KEY` é lida do `.env` do Hermes sem ser exibida nem gravada em logs; `OPENAI_API_KEY` e `HERMES_HOME` são configuradas automaticamente.
- **Detecção de Python com Headroom**: ignora stubs da Microsoft Store e localiza o interpretador com `headroom.cli proxy` funcional (incluindo ambientes pipx/uv).
- **Headroom com provider NVIDIA NIM**: subcomando atualizado com `--port 8787 --mode cache --openai-api-url --provider-name "NVIDIA NIM"`.

---

## 5. Segurança

- Chaves de API nunca são exibidas, copiadas para logs ou gravadas em arquivos de diagnóstico.
- Todo texto de log passa por máscara de segurança automática (`Protect-LogText`).
- O `.env` original nunca é alterado.
- O `config.yaml` nunca é substituído integralmente.
- Provider, modelo e configurações do Hermes não são modificados sem necessidade.
- Não são iniciados processos duplicados.
- Erros e timeouts são tratados.
- Caminhos reais são validados antes de serem utilizados.

---

## 6. Requisitos

- Windows 10 ou Windows 11
- PowerShell 5.1 (ou superior)
- Hermes Agent instalado em `%LOCALAPPDATA%\AmbienteIA\hermes\`
- Headroom 0.44.0 instalado (Python com `headroom.cli proxy`)
- Python em `%LOCALAPPDATA%\Python\pythoncore-3.14-64\python.exe` (ou outro interpretador com Headroom)
- Conexão com a internet para acessar o endpoint NVIDIA NIM

---

## 7. Instalação Manual

1. **Baixe ou clone este repositório** em uma pasta de sua escolha, por exemplo:
   ```powershell
   git clone https://github.com/seu-usuario/AmbienteIA.git
   cd AmbienteIA
   ```

2. **Configure as variáveis de ambiente:**
   Copie `.env.example` para o local real do Hermes (fora do repositório) e preencha com sua `NVIDIA_API_KEY`:
   ```powershell
   copy .env.example %LOCALAPPDATA%\AmbienteIA\hermes\.env
   # Edite o .env e insira sua chave NVIDIA_API_KEY real
   ```

3. **Configure o Hermes:**
   Copie `config.yaml.example` para `%LOCALAPPDATA%\AmbienteIA\hermes\config.yaml` se ainda não existir, e ajuste conforme necessário:
   ```powershell
   copy config.yaml.example %LOCALAPPDATA%\AmbienteIA\hermes\config.yaml
   ```

4. **Verifique o Headroom:**
   Certifique-se de que o Headroom esteja instalado e funcionando na porta 8787:
   ```powershell
   Invoke-WebRequest http://127.0.0.1:8787/livez
   ```

5. **Execute a aplicação:**
   Dê dois cliques em `Iniciar-AmbienteIA.bat`, ou rode no PowerShell:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "Iniciar-AmbienteIA.ps1"
   ```

---

## 8. Caminhos e Portabilidade

Os caminhos do Hermes, Headroom e variáveis de ambiente usam `%LOCALAPPDATA%`, tornando-os portáveis entre usuários Windows.

O diretório de trabalho padrão é `C:\Projetos`. Se você usa outro diretório, edite a variável `HermesWorkDir` no topo de `Core/Ambiente-IA.Core.ps1`.

---

## 9. Backup

O projeto anterior foi preservado na pasta `Backup/` (não publicada no Git). Não modifique nem exclua essa pasta.

---

## 10. Planejado para o Instalador (futuro)

A estrutura está organizada para suportar o desenvolvimento futuro de um instalador Windows (MSI/Inno Setup), incluindo:
- Separação clara entre lógica (`Core/`), interface (`Interface/`) e ponto de entrada (`Iniciar-AmbienteIA.ps1` / `.bat`)
- Templates de configuração (`config.yaml.example`, `.env.example`)
- Módulos independentes de monitoramento e gerenciamento de processos

---

## 11. Licença

MIT License

Copyright (c) 2026 carlostack-dev

---

## 12. Contribuição

Abra issues para bugs ou sugestões. Pull requests são bem-vindos.
