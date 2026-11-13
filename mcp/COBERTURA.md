# Cobertura do MCP

O Trelune tem dois servidores: o nativo (`Trelune --mcp`) e o contêiner (`mcp/server/server.mjs`). Ambos respeitam as permissões em **MCP e assistentes**. O contêiner só acessa diretamente arquivos de mídia montados nele.

| Função do app | MCP |
| --- | --- |
| Publicações, resultados, visão geral e biblioteca | Consultar, criar, editar, duplicar e excluir conforme permissões |
| Opções do editor | Texto e título por rede, mídias, capas, tags, privacidade, Stories, Página Meta e opções do TikTok |
| Agendamento | Agendar e cancelar; a execução local requer o app aberto. Com nuvem configurada, o contêiner também pode enviar o agendamento à nuvem |
| Publicação imediata e nova tentativa | `publish_now`, com permissão específica e app aberto; acompanha-se o resultado com `get_publication` |
| Validação de uma publicação | `validate_publication` usa as contas, regras e hospedagem carregadas pelo app aberto |
| Conexões | `list_connections`, `open_connection` e `disconnect_account`; o app deve estar aberto. A autorização é concluída pelo usuário na interface. Facebook e Instagram compartilham a conexão Meta |
| Métricas e desempenho | `get_insights` consulta os dados carregados pelo app; `refresh_insights` inicia atualização assíncrona |
| Biblioteca | `manage_library` importa ou remove referências e gerencia pastas monitoradas, sem apagar arquivos; requer app aberto |
| Backup e relatório | `export_backup` retorna JSON; `import_backup` adiciona publicações ausentes por ID; `export_csv` retorna o relatório CSV. Requerem app aberto |
| Ajustes gerais | `get_workspace` e `update_workspace` consultam ou alteram nome, usuário, fuso e publicação atrasada; requerem app aberto |

As permissões **Publicar imediatamente** e **Gerenciar biblioteca, backup e ajustes** são independentes das permissões antigas e ficam desligadas por padrão. Habilite-as no aplicativo para usar as respectivas ações. As ações processadas pelo aplicativo exigem a versão atualizada do app aberta; requisições não atendidas expiram para não serem executadas após uma abertura futura. Um retorno de aceitação não garante que a rede concluiu o envio: consulte a publicação. Após um tempo esgotado, verifique o estado antes de repetir.

A conexão OAuth, a escolha de credenciais, configurações da hospedagem e infraestrutura AWS, permissões do MCP e ajustes visuais continuam sendo feitos na interface; o MCP não recebe nem exibe segredos. As métricas dependem das permissões concedidas pelas redes. O servidor em contêiner precisa ser reconstruído após alterações no código (`mcp/install.sh`).

Para testar os dois servidores em pastas temporárias, execute `swift test` e `node mcp/tests/parity.mjs` na raiz do projeto. Esses testes não publicam em redes reais.
