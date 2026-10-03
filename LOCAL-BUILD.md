# Локальная сборка форка

Ветка `codex/macos-sip-enabled` основана на стабильном теге `v7.1.25`, а не на движущемся `master`. `origin` — собственный GitHub-форк; `upstream` — `asmvik/yabai`. Это позволяет редактировать исходники и отдельно принимать upstream изменения.

```sh
YABAI_SIGNING_IDENTITY='имя постоянного сертификата' ./scripts/install-local-source.sh
~/.local/bin/yabai --version
~/.local/bin/yabai --check-accessibility
```

Скрипт собирает оптимизированный универсальный бинарник, подписывает его, проверяет подпись и устанавливает в `~/.local/bin`. Прежний бинарник и сведения о сборке сохраняются в `~/.local/state/yabai-source`. Для повторных сборок используйте тот же сертификат и путь: иначе macOS может потребовать выдать Accessibility заново. `make install` upstream выполняет только сборку; установку выполняет этот скрипт.

`--check-accessibility` — добавленная команда форка: код 0 означает предоставленный доступ, код 3 — отсутствие доступа. Она не показывает запрос разрешения, не запускает event loop, не читает конфиг и не размещает окна. Перед запуском самого менеджера доступ нужно предоставить через системные настройки macOS.

SIP сохраняется. Скрипт не запускает yabai, не создаёт LaunchAgent, не загружает scripting addition и не меняет sudoers. Не запускайте одновременно два оконных менеджера. Раскладка BSP работает с нативными Spaces macOS; виртуальные рабочие столы, обзор и жесты другого менеджера не переносятся автоматически. Установка сама по себе не даёт постоянный верхний слой сторонним окнам.

Исходная документация: [настройка yabai](https://github.com/asmvik/yabai/wiki/Configuration), [установка](https://github.com/asmvik/yabai/wiki/Installing-yabai-(latest-release)), [границы SIP](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection).
