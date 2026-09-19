# moodle-safe-update

Atualização segura do Moodle 5.x rodando em Docker Compose, com pré-voo antes
de tirar o site do ar, backup completo com manifesto, rollback de um comando e
conferências depois do upgrade.

**Versão 2 (2026-09-19).** Reescrita depois do primeiro uso real, que levou um
laboratório de 5.1.5+ para 5.1.7 e mostrou sete problemas na versão 1 (ver
[Lições do primeiro uso](#lições-do-primeiro-uso-real)). A v1 falhava antes de
trocar uma linha de código e deixava o site em manutenção.

## Por que este script existe

O Moodle **não tem botão de "atualizar agora" para o core**, de propósito:
dar ao servidor web permissão de escrita sobre o próprio código que ele
executa é a superfície que um webshell explora. O core é trocado "por fora"
(git ou pacote) e depois roda a migração de banco (`admin/cli/upgrade.php`).
Este script faz esse fluxo com as proteções que uma atualização às pressas
costuma pular.

## Comandos

```bash
./update-moodle.sh check [--to v5.1.7]     # pré-voo: não mexe no site nem no código em uso
./update-moodle.sh minor [--to v5.1.7]     # atualiza dentro da mesma linha (5.1.x)
./update-moodle.sh major MOODLE_502_STABLE # troca de versão maior
./update-moodle.sh rollback backups/manifest-<versão>-<data>.env
```

Sem `--to`, o `minor` vai para a ponta da branch (a build semanal, "5.1.7+").
Com `--to v5.1.7`, vai para a versão oficial exata. **Para produção, use sempre
uma tag**: a ponta da branch muda toda semana, e uma versão retirada (como a
5.1.6, desaconselhada pela própria Moodle) nunca entra por acidente.

## O que acontece num update

Com o site **no ar**:

1. **Pré-voo.** Containers rodando; git acessível com o dono dos arquivos;
   remoto alcançável; destino existe, é da mesma linha e é mais novo (lido do
   `version.php`, não do histórico do git); arquivos do core alterados (só
   permissão é aceito e restaurado; conteúdo alterado para tudo); plugins
   registrados sem pasta no disco; upgrade já pendente; espaço para os
   backups. Já baixa o commit de destino. Qualquer problema aqui para o script
   **sem** tirar o site do ar.

Com o site **em manutenção**:

2. **Manutenção e cron.** Liga a manutenção e pede saída graciosa (SIGTERM)
   ao cron que já estava rodando. O laço de keepalive do cron do Moodle
   continua executando tarefas por minutos depois que a manutenção liga; só
   quem inicia depois disso é bloqueado.
3. **Backup.** Banco em `pg_dump -Fc`, código inteiro menos `.git` (a v1 só
   guardava `public/`, deixando `vendor/` e `admin/cli/` de fora) e um
   **manifesto** com versões, commits e arquivos. Uma ref git
   (`refs/moodle-safe-update/before-<data>`) segura o commit de antes enquanto
   o backup existir.
4. **Troca.** Restaura bits de permissão perdidos no core, leva a branch ao
   destino com `git reset --keep` (funciona em clone raso e recusa apagar
   alteração local), roda `composer install` só se o `composer.lock` mudou
   (preservando dependências de desenvolvimento se já estavam instaladas) e o
   `upgrade.php` com `max_input_vars` suficiente para a checagem de ambiente.
5. **Conferências.** Limpa caches, corrige dono dos caches, confirma que não
   sobrou upgrade pendente nem plugin sem pasta, compara o hash dos plugins
   "sensíveis".
6. **Volta ao ar** e confere a página de login por HTTP.

Qualquer falha a partir do passo 2 deixa o site em manutenção e imprime o
comando de rollback. Cada execução grava `backups/update-<data>.log` com o
tempo de cada etapa.

## Rollback

```bash
./update-moodle.sh rollback backups/manifest-<versão>-<data>.env
```

Volta o código ao commit de antes (mais o tar do código) e o banco ao dump.
O banco é restaurado **num banco novo** e só no fim os nomes são trocados: o
banco em uso não é tocado até a cópia estar completa, e fica guardado como
`<banco>_pre_rollback_<data>` para conferência. O usuário do banco precisa de
`CREATEDB`.

## Pré-requisitos

- Moodle 5.x em Docker Compose, código do core num clone git
  (`moodle/moodle.git`) em `code/`, docroot em `code/public/`, CLI em
  `code/admin/cli/`. Funciona em clone raso (`--depth 1`).
- PostgreSQL (`pg_dump`, `pg_restore`, `psql` no container do banco).
- No host: `git`, `tar`, `curl`, `flock`, `awk`. No container da aplicação:
  `composer`, `pgrep`, `pkill`.
- `sudo` sem senha para os comandos abaixo.

### Sudo com privilégio mínimo

O git e a restauração do código rodam **com o mesmo dono dos arquivos**
(`sudo -u #<uid>`), nunca como root: rodar git como root num repositório de
outro usuário cai no erro *dubious ownership* e ainda deixa arquivo de root no
meio do código. A leitura para backup e as somas de verificação rodam como
root. Exemplo para o dono uid 33 (`/etc/sudoers.d/moodle-safe-update`, editar
com `visudo -f`):

```
hellanio ALL=(#33)  NOPASSWD: /usr/bin/git -C /opt/moodle-docker/code *, \
                              /usr/bin/tar -C /opt/moodle-docker/code -xzf *
hellanio ALL=(root) NOPASSWD: /usr/bin/tar -C /opt/moodle-docker/code --exclude=./.git -czf - ., \
                              /usr/bin/du -sm --exclude=.git /opt/moodle-docker/code, \
                              /usr/bin/find /opt/moodle-docker/code/public/*, \
                              /usr/bin/xargs -0 sha256sum
```

## Configuração (`.env` do projeto)

| Variável | Padrão | Para que serve |
|---|---|---|
| `MOODLE_SERVICE` / `DB_SERVICE` | `moodle` / `db` | Nomes dos serviços no `docker-compose.yml` |
| `MOODLE_CONTAINER_PATH` | `/var/www/moodle` | Raiz do código **dentro** do container |
| `WEB_USER` | `www-data` | Usuário do PHP dentro do container |
| `PHP_VERSION` | *(vazio)* | Sufixo do binário, ex. `8.3` para `php8.3` |
| `SENSITIVE_PLUGINS_CSV` | *(vazio)* | Forks na árvore do core a conferir, ex. `mod/attendance` |
| `KEEP_BACKUPS` | `5` | Conjuntos de backup (banco + código + manifesto) mantidos |
| `CLI_MAX_INPUT_VARS` | `5000` | Valor passado ao PHP de linha de comando no upgrade |
| `CRON_WAIT` | `300` | Segundos esperando o cron em curso terminar |
| `COMPOSE` | `docker compose` | Troque para `docker-compose` no Compose v1 |

## Lições do primeiro uso real

Laboratório Docker, 5.1.5+ para 5.1.7, em 19/09/2026. Cada item virou uma
mudança no script.

| O que aconteceu | Consequência na v1 | Como a v2 trata |
|---|---|---|
| `sudo git` num repositório de outro dono: *dubious ownership* | Falha no `git fetch` **depois** de ligar a manutenção: site fora do ar sem ter trocado nada | git com o dono dos arquivos; checado no pré-voo |
| Sete arquivos do core sem o bit de execução (efeito de um `chmod` antigo) | Contaria como alteração local | Pré-voo separa permissão de conteúdo; restaura permissão, para em conteúdo |
| Clone raso + buscar tag sem limite | Baixou o histórico inteiro do Moodle: `.git` de ~80 MB para 763 MB, 2 minutos | Busca só o commit de destino (`--depth=1`) |
| Ancestralidade do git em clone raso | Falso "não é avanço rápido" depois de recortar o histórico | Segurança pelo `version.php` (mesma linha, versão maior) e troca com `reset --keep` |
| Cron com keepalive rodando quando a manutenção liga | Tarefas rodando durante backup e upgrade | SIGTERM e espera antes do backup |
| `composer install --no-dev` fixo | Apagaria PHPUnit e Behat de um ambiente de desenvolvimento | Preserva dependências de desenvolvimento se já existem; só roda se o lockfile mudou |
| Rollback com `pg_restore --clean --single-transaction` em 1.634 tabelas | "sem memória compartilhada" (`max_locks_per_transaction`): código voltou, banco não | Restaura num banco novo e troca os nomes no fim |

Tempos medidos no laboratório (banco de 84 a 202 MB, 24 plugins adicionais):
update completo em 40 a 43 s, com 36 s de manutenção, dos quais 22 s de
`upgrade.php`; rollback em 14 a 25 s.

## Limitações conhecidas

- **Só Docker Compose e git.** Um Moodle instalado direto no servidor, a
  partir de pacote e sem git, precisa de outro modo (core novo montado ao lado,
  com as pastas dos plugins adicionais copiadas, e troca de diretório). É o
  próximo passo planejado.
- **Só PostgreSQL.**
- **Não atualiza plugins**, só o core.
- O `check` não altera o site nem os arquivos em uso, mas grava no `.git` o
  commit de destino que baixou.

## Licença

MIT — veja [LICENSE](LICENSE). Teste em homologação antes de confiar em
produção sem supervisão.
