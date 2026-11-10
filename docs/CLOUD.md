# Hospedagem de mídia e publicação pela nuvem (AWS)

Ambos são opcionais e rodam na **sua** conta AWS. O projeto não mantém servidor nem conta compartilhada.

- **Hospedagem de mídia (S3):** necessária para Instagram, mídia no Threads e fotos no TikTok, que só aceitam URL HTTPS pública. O app envia o arquivo do Mac para o bucket na hora de publicar.
- **Publicação pela nuvem (EventBridge Scheduler + Lambda):** publica no horário mesmo com o Mac desligado.

## 1. Conta e AWS CLI

1. Crie uma conta em [aws.amazon.com](https://aws.amazon.com/) (há camada gratuita).
2. Instale e entre na AWS CLI: `brew install awscli` e `aws login` (ou `aws configure sso`).

## 2. Bucket de mídia

1. Crie um bucket S3 (ex.: `meu-trelune-midia`) na região que preferir.
2. Libere leitura pública **só do prefixo** usado pelo app (padrão `trelune/`), por política do bucket ou CloudFront. Exemplo de política:

```json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::meu-trelune-midia/trelune/*"}]}
```

3. Opcional: uma regra de ciclo de vida que apague `trelune/` e `scheduled/` depois de alguns dias.

## 3. Lambda, papéis e usuário de envio

```bash
BUCKET=meu-trelune-midia REGION=us-east-1 ./cloud/deploy.sh
```

O script usa a sessão da AWS CLI e cria (ou atualiza), todos com o prefixo `NAME` (padrão `trelune`):

| Recurso | Nome |
|---|---|
| Lambda que publica | `trelune-publisher` |
| Papel da Lambda | `trelune-publisher` |
| Papel do EventBridge Scheduler | `trelune-scheduler` |
| Usuário IAM só de envio, usado pelo Mac | `trelune-uploader` |
| Parâmetros criptografados das conexões | `/trelune/vault/*` (SSM Parameter Store) |

Os valores podem ficar em um `.env` local (veja `.env.example`).

## 4. Configurar o app

1. **Ajustes → Hospedagem:** bucket, região e prefixo. Clique em **Gerar chave com a AWS CLI** para criar a chave do usuário `trelune-uploader` direto no Chaves (a chave secreta nunca é exibida) e depois em **Testar envio e leitura**.
2. **Ajustes → Agendamento:** ligue **Publicar pela nuvem**. Se você usou outro `NAME` no deploy, informe o mesmo prefixo.

O app descobre o ID da conta pela própria chave (STS `GetCallerIdentity`) e monta os ARNs da Lambda e do papel; nenhum ID de conta fica no código.

## Servidor MCP em Docker

Com a publicação pela nuvem ligada, o app grava `mcp-aws.json` (permissão 600) na pasta de dados para o contêiner do MCP agendar com o app fechado. Veja [`mcp/`](../mcp/).
