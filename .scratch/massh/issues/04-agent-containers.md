# 04: Agent: Container

**What to build:** В Snapshot появляются запущенные Docker-контейнеры (имя, образ, статус, CPU %, RAM занято/лимит, порты), а порты, проброшенные контейнером, получают владельцем Container. Если Docker на Server нет или он недоступен, Snapshot об этом сообщает, остальное работает.

**Blocked by:** 03

**Status:** done

- [x] Container перечислены с именем, образом, статусом, CPU %, RAM и лимитом, портами
- [x] Порт, опубликованный контейнером, принадлежит Container, а не процессу docker-proxy
- [x] Без Docker Snapshot содержит признак «Docker не установлен» и Agent не падает
- [x] Интеграционные тесты: контейнер с Docker и тестовым контейнером; контейнер без Docker

## Comments

- Known limitation: the `massh` user joins group `docker` only if the group exists at install time. If Docker is installed later, run "Обновить Agent" once so the Agent can reach the Docker socket.
