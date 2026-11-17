# Шура | ИИ-помощница

Шура 💜 — хитрая цифровая девчонка на базе ChatGPT, живущая в мессенджере MAX. Поможет разобраться с чем угодно, подкинет неожиданную идею и иногда подколет. Ну, разберёмся!

![Banner](docs/banner2.jpg)

![Latest Release](https://img.shields.io/github/v/release/TupiNUMBooR/shura-ai)
![Release Date](https://img.shields.io/github/release-date/TupiNUMBooR/shura-ai)
![Build](https://img.shields.io/github/actions/workflow/status/TupiNUMBooR/shura-ai/release.yml?label=build&logo=githubactions)  
![Top Lang](https://img.shields.io/github/languages/top/TupiNUMBooR/shura-ai?logo=gnubash)
![ms-max Size](https://img.shields.io/docker/image-size/tupinumboor/ms-max/latest?label=ms-max&logo=docker)
![ms-openai Size](https://img.shields.io/docker/image-size/tupinumboor/ms-openai/latest?label=ms-openai&logo=docker)

**Links:** [GitHub](https://github.com/TupiNUMBooR/shura-ai) | [Docker Hub: ms-max](https://hub.docker.com/r/tupinumboor/shura-ai-ms-max) | [Docker Hub: ms-openai](https://hub.docker.com/r/tupinumboor/shura-ai-ms-openai)

## Настройка

Создай `.env` в корне репозитория и укажи:

- `OPENAI_API_KEY` — [ключ OpenAI](https://platform.openai.com/api-keys).
- `MAX_BOT_TOKEN` — токен бота из [MAX для партнёров](https://business.max.ru).
- `MAX_DEBUG_CHAT_ID` — ID чата для тестов, ошибок и отладочных сообщений (необязательно).
- `DOCKERHUB_USERNAME` — имя пользователя Docker Hub для публикации образов и обновления README.
- `DOCKERHUB_TOKEN` — Docker Hub [Personal Access Token](https://app.docker.com/settings/personal-access-tokens) с правами `Repo Read, Write, Delete`.

Для настройки CI/CD авторизуйся в GitHub командой `gh auth login`, затем запусти `tools/set-repo-env.sh`.

---
![](docs/avatar-debug.jpg)
