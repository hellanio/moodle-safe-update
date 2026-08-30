# moodle-safe-update

Script de atualização automatizada do Moodle (rodando em Docker Compose) com
backup automático, verificação de integridade de plugins e parada segura em
caso de falha. Feito para rodar via cron em produção sem supervisão.

## Por que este script existe

O Moodle **não tem um botão de "atualizar agora" para o core**, ao contrário
de sistemas como WordPress. Isso é proposital: dar ao processo do servidor
web (`www-data`) permissão de escrita sobre o próprio código PHP que ele está
executando é a mesma superfície de ataque que um webshell explora — se algum
dia existir uma vulnerabilidade de upload/injeção, ela vira execução remota
de código permanente. Por isso o Moodle core só é atualizado trocando os
arquivos "por fora" (git, ou baixando um pacote) com um usuário que **não**
seja o do servidor web, e depois rodando a migração de banco
(`admin/cli/upgrade.php`).

Esse script automatiza exatamente esse fluxo, com as proteções que uma
atualização manual às pressas normalmente pula:

1. Liga o **modo de manutenção** (usuários comuns não acessam o site durante a atualização)
2. **Backup do banco** (`pg_dump` comprimido)
3. **Backup do código** (`tar.gz` de `code/public/`, do jeito que estava *antes* da atualização)
4. `git fetch` + `git pull --ff-only` (modo `minor`) **ou** troca de branch (modo `major`, só quando pedido explicitamente — nunca automático)
5. `composer install` (só reinstala se o `composer.lock` mudou)
6. `admin/cli/upgrade.php --non-interactive` (migração de banco)
7. Limpeza de caches
8. Confere se plugins marcados como "sensíveis" (ver [Customização](#customização)) não foram sobrescritos pela atualização do core
9. Desliga o modo de manutenção

**Em qualquer etapa que falhar, o script para imediatamente**, mantém o modo
de manutenção ativo (site protegido, não fica servindo uma versão quebrada) e
preserva os dois backups intactos para restauração.

## Pré-requisitos

- Um Moodle 5.x rodando via **Docker Compose**, com a estrutura de diretórios
  do Moodle 5.x: código na raiz do repositório git, docroot em `code/public/`
  (onde fica `version.php`), scripts CLI em `code/admin/cli/*.php`.
- **PostgreSQL** como banco (o script usa `pg_dump`; ver [Limitações](#limitações-conhecidas)).
- Os serviços do `docker-compose.yml` respondendo por `moodle` e `db` (ou
  configure os nomes reais, ver [Customização](#customização)).
- `git`, `tar`, `gzip`, `sha256sum` no host; `composer` dentro do container da aplicação.
- O usuário que roda o script precisa de `sudo` sem senha para **apenas** os
  comandos `git` (dentro de `code/`) e `chown` (ver [Sudoers](#sudo-com-privilégio-mínimo) abaixo) — é assim que o código é trocado por um usuário diferente do `www-data`.

Layout esperado do projeto:

```
meu-moodle/
├── docker-compose.yml
├── .env                    # DB_NAME, DB_USER, etc. — nunca versionado
├── code/                   # clone git do Moodle (moodle/moodle.git)
│   ├── admin/cli/*.php
│   └── public/             # docroot — version.php fica aqui
├── backups/                # criado automaticamente pelo script
└── update-moodle.sh        # este script, copiado pra dentro do projeto
```

## Instalação

```bash
cd /caminho/do/seu/projeto-moodle
curl -fsSLO https://raw.githubusercontent.com/hellanio/moodle-safe-update/main/update-moodle.sh
chmod +x update-moodle.sh
```

(ou clone o repositório e copie o script — o importante é que ele fique na
raiz do seu projeto docker-compose, ao lado de `docker-compose.yml` e `code/`).

### Sudo com privilégio mínimo

O script usa `sudo` só para `git -C code/ ...` e `chown -R www-data:www-data
code/` — porque quem troca o código precisa ser o dono dos arquivos no host,
não o `www-data` do container. **Nunca dê `NOPASSWD: ALL`.** Restrinja aos
comandos exatos, com o caminho absoluto do seu projeto. Exemplo
(`/etc/sudoers.d/moodle-safe-update`, editar com `visudo -f`):

```
# Ajuste "hellanio" e o caminho para o seu usuario e projeto
hellanio ALL=(root) NOPASSWD: /usr/bin/git -C /opt/moodle-docker/code *, \
                              /usr/bin/chown -R www-data\:www-data /opt/moodle-docker/code
```

Teste com `sudo -l` (deve listar só essas duas entradas) antes de agendar o
script sem supervisão.

## Uso

### Atualização menor (patch dentro da mesma branch)

Essa é a atualização "de rotina" — mesma versão maior do Moodle (ex.:
5.1.x → 5.1.y), normalmente só correções de bug/segurança:

```bash
./update-moodle.sh minor
```

Saída típica (quando há atualização disponível):

```
[update] 2026-08-30 03:00:01 - Moodle atual: 5.1.2 (2026042101) (branch MOODLE_501_STABLE) | modo: minor
[update] 2026-08-30 03:00:01 - Ativando modo de manutencao...
[update] 2026-08-30 03:00:03 - Gerando backup do banco em backups/moodle-5.1.2_(2026042101)-20260830-030001.sql.gz...
[update] 2026-08-30 03:00:47 - Backup concluido: 312M.
[update] 2026-08-30 03:00:47 - Gerando backup do codigo em backups/code-5.1.2_(2026042101)-20260830-030001.tar.gz...
[update] 2026-08-30 03:00:52 - Backup do codigo concluido: 89M.
[update] 2026-08-30 03:00:52 - Buscando atualizacoes do repositorio oficial...
[update] 2026-08-30 03:00:55 - Codigo atualizado: a1b2c3d4 -> e5f6a7b8.
[update] 2026-08-30 03:01:10 - Atualizando dependencias do Composer...
[update] 2026-08-30 03:01:22 - Executando upgrade do Moodle (non-interactive)...
[update] 2026-08-30 03:01:24 - Limpando caches...
[update] 2026-08-30 03:01:26 - OK: 'mod/attendance' permaneceu inalterado (patches locais preservados).
[update] 2026-08-30 03:01:26 - Desativando modo de manutencao...
[update] 2026-08-30 03:01:26 - Atualizacao concluida com sucesso: 5.1.2 (2026042101) -> 5.1.3 (2026042250).
```

Quando **não há** atualização disponível, o script encerra rápido e sem
mexer em nada além de ligar/desligar o modo de manutenção:

```
[update] 2026-08-30 03:00:01 - Moodle atual: 5.1.3 (2026042250) (branch MOODLE_501_STABLE) | modo: minor
[update] 2026-08-30 03:00:01 - Ativando modo de manutencao...
[update] 2026-08-30 03:00:03 - Gerando backup do banco em backups/moodle-...sql.gz...
[update] 2026-08-30 03:00:47 - Backup concluido: 312M.
[update] 2026-08-30 03:00:47 - Gerando backup do codigo em backups/code-...tar.gz...
[update] 2026-08-30 03:00:52 - Backup do codigo concluido: 89M.
[update] 2026-08-30 03:00:52 - Buscando atualizacoes do repositorio oficial...
[update] 2026-08-30 03:00:53 - Nenhuma atualizacao disponivel na MOODLE_501_STABLE. Desativando manutencao e saindo.
```

### Atualização maior (troca de versão)

Passar de uma versão maior para outra (ex.: 5.1 → 5.2) **exige informar a
branch de destino explicitamente** — o script nunca faz isso sozinho, porque
é o momento de maior risco de incompatibilidade com plugins customizados:

```bash
./update-moodle.sh major MOODLE_502_STABLE
```

**Antes de rodar isso em produção:**
1. Rode primeiro em um ambiente de homologação com uma cópia real dos dados.
2. Confira o changelog oficial da nova versão maior (mudanças de API que quebram plugins de terceiros).
3. Para cada plugin customizado seu, confira o campo `$plugin->supported` em `version.php` — se ele não cobrir a nova versão, o Moodle pode desativá-lo automaticamente no upgrade.
4. Só depois disso, rode contra produção — de preferência fora do horário de pico.

### Agendando via cron

Atualizações menores são seguras de rodar automaticamente (patches de
bug/segurança, sem mudança de API). Sugestão: toda madrugada de domingo.

```bash
crontab -e
```

```cron
0 3 * * 0 /caminho/do/seu/projeto-moodle/update-moodle.sh minor >> /caminho/do/seu/projeto-moodle/backups/update.log 2>&1
```

Atualizações **maiores nunca devem ir para o cron** — rode manualmente,
acompanhando a saída.

### Rodando manualmente pela primeira vez

Antes de confiar o script ao cron, rode manualmente e acompanhe a saída
inteira pelo menos uma vez:

```bash
./update-moodle.sh minor
echo "saida: $?"
```

Se algo falhar, o script imprime `ERRO: ...` com o motivo e qual backup usar
para restaurar — o site fica em modo de manutenção até você resolver.

## Restaurando a partir de um backup

Os backups ficam em `backups/`, pareados pelo mesmo timestamp:
- `moodle-<versao>-<timestamp>.sql.gz` — dump do banco
- `code-<versao>-<timestamp>.tar.gz` — snapshot de `code/public/`

**Restaure os dois juntos, do mesmo timestamp.** Restaurar só o banco com o
código novo (ou vice-versa) deixa o Moodle com schema e código
desalinhados — o `admin/cli/upgrade.php` vai reclamar de versão incompatível.

```bash
# 1. Modo de manutencao ligado (se ainda nao estiver)
docker compose exec -T moodle su -s /bin/bash www-data -c \
  "php8.3 /var/www/moodle/admin/cli/maintenance.php --enable"

# 2. Restaurar o codigo
sudo rm -rf code/public
sudo tar -C code -xzf backups/code-<versao>-<timestamp>.tar.gz
sudo chown -R www-data:www-data code/

# 3. Restaurar o banco (recriando do zero)
gunzip -c backups/moodle-<versao>-<timestamp>.sql.gz | \
  docker compose exec -T db psql -U moodleuser -d moodle

# 4. Limpar caches e desligar manutencao
docker compose exec -T moodle su -s /bin/bash www-data -c \
  "php8.3 /var/www/moodle/admin/cli/purge_caches.php"
docker compose exec -T moodle su -s /bin/bash www-data -c \
  "php8.3 /var/www/moodle/admin/cli/maintenance.php --disable"
```

## Segurança

- **Sem update de core "de um clique"**, de propósito — ver [Por que este script existe](#por-que-este-script-existe).
- `www-data` nunca tem permissão de escrita sobre o código — quem troca o
  código é o usuário do host, via `sudo` restrito a comandos específicos
  (nunca `NOPASSWD: ALL`).
- Nenhuma credencial fica dentro do script — `DB_USER`/`DB_NAME` vêm do
  `.env` do projeto, que nunca deve ser versionado.
- `git pull --ff-only` — nunca força merge nem sobrescreve histórico
  divergente; se não der fast-forward, o script falha em vez de arriscar um
  merge automático.
- Validação do nome da branch antes de usar em qualquer comando `git`
  (defesa em profundidade contra um argumento malformado).
- **Fail-fast em toda etapa**: qualquer comando que falhar interrompe o
  script imediatamente, mantendo o modo de manutenção ligado e os backups
  intactos — nunca deixa o site no ar com uma atualização pela metade.
  (Exceção deliberada: falha no `purge_caches.php` só gera aviso, não aborta
  — um cache desatualizado não é motivo para travar o site em manutenção.)
- Verificação de integridade pós-update para plugins marcados como
  "sensíveis" (forks seus que vivem dentro da árvore do core) — avisa no log
  se o conteúdo mudou, para você conferir antes de considerar a atualização
  concluída.
- Recomendado: teste sempre em homologação antes de rodar contra produção,
  especialmente em atualizações `major`.

## Customização

Todas as variáveis abaixo podem ir no `.env` do projeto (mesmo arquivo que
já tem `DB_NAME`/`DB_USER`) ou ser exportadas no ambiente antes de chamar o
script:

| Variável | Default | Para que serve |
|---|---|---|
| `MOODLE_SERVICE` | `moodle` | Nome do serviço da aplicação no `docker-compose.yml` |
| `DB_SERVICE` | `db` | Nome do serviço do banco no `docker-compose.yml` |
| `MOODLE_CONTAINER_PATH` | `/var/www/moodle` | Docroot do Moodle **dentro** do container |
| `SENSITIVE_PLUGINS_CSV` | *(vazio)* | Lista separada por vírgula de plugins fork-do-core a conferir após o update, ex.: `mod/attendance,local/outro` |
| `KEEP_BACKUPS` | `14` | Quantos backups (banco + código) manter antes de apagar os mais antigos |
| `COMPOSE` | `docker compose` | Troque para `docker-compose` se ainda usa o Compose v1 |

Veja `.env.example` para um modelo comentado.

## Limitações conhecidas

- **Só PostgreSQL.** O backup usa `pg_dump`; não há suporte a
  MySQL/MariaDB nesta versão. Se você precisar, é uma boa contribuição via PR
  (trocar o bloco de backup por uma checagem de `DB_DRIVER`).
- **Não verifica compatibilidade de plugins customizados** com a nova versão
  do core antes do upgrade — isso ainda é responsabilidade sua, especialmente
  em atualizações `major` (ver checklist na seção de uso).
- **Não atualiza os plugins em si**, só o core do Moodle. Se você mantém
  plugins customizados em repositórios git próprios dentro de
  `code/public/...`, atualizá-los é um processo separado.
- A verificação de integridade (`SENSITIVE_PLUGINS_CSV`) detecta *que* o
  conteúdo mudou, não repara automaticamente — é um alerta para revisão
  manual, não um mecanismo de reaplicação de patch.

## Licença

MIT — veja [LICENSE](LICENSE). Use por sua conta e risco; teste em
homologação antes de confiar em produção sem supervisão.
