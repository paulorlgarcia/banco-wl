# Banco WL — Guia definitivo de instalação (100% gratuito)

Este é o passo a passo completo, do zero até o painel no ar, usando
**Supabase** (banco de dados) + **GitHub Pages** (hospedagem do painel).

Arquivos que você vai usar, **nesta ordem**:

1. `schema.sql` — cria a estrutura base (turmas, alunos, contas, transações)
2. `migracao_pacotes_juros.sql` — adiciona os pacotes de juros (básico + personalizados)
3. `migracao_numero_aluno.sql` — adiciona o número do aluno
4. `migracao_atribuicao_pacotes.sql` — unifica a atribuição de pacotes (o Básico passa a ser atribuível a aluno individual, turma ou escola toda, igual aos personalizados)
5. `migracao_login_aluno.sql` — adiciona RA e senha, e a consulta somente-leitura do aluno
6. `painel-professor.html` — o painel que os professores vão usar
7. `index.html` — a página de consulta que os alunos vão usar (porta de entrada padrão do site)

---

## Parte 1 — Banco de dados (Supabase)

### 1.1 Criar o projeto
1. Acesse [supabase.com](https://supabase.com) → crie uma conta gratuita.
2. **New Project** → escolha um nome (ex: `banco-wl`) e uma senha de banco
   (guarde-a, mas você não vai precisar dela no dia a dia).
3. Aguarde o projeto ficar pronto (leva 1-2 minutos).

### 1.2 Rodar os cinco arquivos SQL, na ordem
1. No menu lateral, abra **SQL Editor** → **New query**.
2. Cole o conteúdo de `schema.sql` inteiro → **Run**.
3. Nova query → cole `migracao_pacotes_juros.sql` inteiro → **Run**.
4. Nova query → cole `migracao_numero_aluno.sql` inteiro → **Run**.
5. Nova query → cole `migracao_atribuicao_pacotes.sql` inteiro → **Run**.
6. Nova query → cole `migracao_login_aluno.sql` inteiro → **Run**.

> Se aparecer erro sobre `pg_cron`, vá em **Database > Extensions** e
> confirme que `pg_cron` está habilitada (é gratuita, só precisa ativar).

### 1.3 Cadastrar os professores
1. Vá em **Authentication > Users** → **Add user > Create new user**.
2. E-mail + senha de cada professor. Não marque "enviar e-mail de
   confirmação" — o usuário já fica pronto pra uso.
3. Repita para cada professor. **Não crie nenhum usuário para alunos** —
   eles nunca acessam este sistema.

### 1.4 Pegar as chaves de conexão
1. **Project Settings > API**.
2. Copie:
   - **Project URL** (ex: `https://xxxxx.supabase.co`)
   - **anon public key** (chave longa)

---

## Parte 2 — Configurar o painel e a página do aluno

Abra `painel-professor.html` **e também** `index.html` num editor de
texto — os dois têm o mesmo bloco de configuração perto do topo:

```js
const CONFIG = {
  SUPABASE_URL: "COLE_AQUI_A_URL_DO_SEU_PROJETO_SUPABASE",
  SUPABASE_ANON_KEY: "COLE_AQUI_A_CHAVE_ANON_PUBLIC_DO_SUPABASE"
};
```

Cole a mesma URL e a mesma chave do passo 1.4 **nos dois arquivos**.
Nada mais precisa ser alterado em nenhum dos dois.

> A chave "anon public" é segura para ficar exposta no código — quem
> protege os dados de verdade são as regras de segurança (RLS) e as
> funções de banco de dados que já estão nos arquivos SQL. O aluno
> nunca ganha acesso direto a nenhuma tabela; ele só consegue chamar
> uma função que confere o RA e a senha e devolve apenas os dados da
> própria conta.

---

## Parte 3 — Publicar no GitHub Pages

Como você já usa git no dia a dia, é rápido — os dois arquivos ficam
no mesmo repositório, como duas páginas separadas:

```bash
# 1. Crie um repositório novo vazio em github.com (ex: banco-wl)
#    — pode ser público ou privado, tanto faz para a segurança do sistema

# 2. Localmente:
mkdir banco-wl && cd banco-wl
git init
cp /caminho/para/painel-professor.html .
cp /caminho/para/index.html .
git add painel-professor.html index.html
git commit -m "Painel do professor e consulta do aluno — Banco WL"
git branch -M main
git remote add origin https://github.com/SEU_USUARIO/banco-wl.git
git push -u origin main
```

Depois:

1. No GitHub, vá em **Settings > Pages** do repositório.
2. Em **Build and deployment > Source**, escolha **Deploy from a branch**.
3. Branch: `main`, pasta: `/ (root)` → **Save**.
4. Espere 1-2 minutos. Os links ficam:
   - Alunos (porta de entrada padrão): `https://seuusuario.github.io/banco-wl/`
   - Professores: `https://seuusuario.github.io/banco-wl/painel-professor.html`

Cada página tem um linkzinho discreto para a outra ("Sou professor" /
"Sou aluno"), então quem cair na página errada consegue navegar sem
precisar saber o endereço de cor.

Toda vez que quiser atualizar qualquer um dos dois (ex: depois de uma
nova versão que eu te passar), basta substituir o arquivo local e rodar:

```bash
git add painel-professor.html index.html
git commit -m "Atualiza painel e consulta do aluno"
git push
```

O GitHub Pages republica sozinho em cerca de 1 minuto.

---

## Parte 4 — Testar tudo

Checklist antes de usar em sala:

- [ ] Abrir `painel-professor.html` pelo GitHub Pages e conseguir logar com um professor cadastrado
- [ ] Criar uma turma de teste
- [ ] Adicionar 2-3 alunos (com número e RA)
- [ ] Testar depósito, saque e transferência entre eles
- [ ] Abrir o extrato de um aluno e conferir se as transações aparecem
- [ ] Ir em **Configurações**, conferir se o Pacote Básico aparece
- [ ] Criar um pacote personalizado de teste e atribuir a um aluno
- [ ] Conferir se a coluna "Rendimento" mostra a taxa somada (básico + bônus)
- [ ] Na linha de um aluno, clicar em "Senha" e definir uma senha de teste
- [ ] Abrir `index.html` (a raiz do site) numa aba anônima, logar com o
      RA e a senha, e conferir se aparecem saldo, pacotes e extrato
      daquele aluno — e só daquele aluno
- [ ] Tentar logar em `aluno.html` com RA ou senha errados e confirmar
      que a mensagem de erro aparece, sem revelar qual dos dois está errado
- [ ] Deslogar do painel do professor e confirmar que a tela de login aparece de novo
- [ ] (Opcional) Esperar até o dia seguinte e conferir se o rendimento
      automático rodou sozinho (aparece no extrato como "Rendimento
      diário automático")

Se algum desses passos falhar, o erro mais comum é a URL ou a chave do
Supabase coladas errado no `CONFIG` do `index.html` — vale conferir
primeiro, sem espaços extras nem aspas faltando.

---

## Segurança do login do aluno — o que saber

- O aluno nunca acessa nenhuma tabela do banco diretamente. Ele só pode
  chamar uma função que verifica RA + senha e devolve os dados da
  própria conta — nada além disso.
- A senha do aluno é guardada **sempre criptografada** (hash), nunca em
  texto puro, nem mesmo o professor consegue vê-la depois de definida
  — só redefinir.
- Enquanto a aba do `aluno.html` estiver aberta, o navegador guarda o
  RA e a senha temporariamente (na memória da aba) para poder atualizar
  a tela sem pedir login de novo a cada clique. Isso é apagado ao
  clicar em "Sair" ou fechar a aba.
- Este nível de segurança é adequado para um dinheiro **simbólico e
  pedagógico** de sala de aula — não é o mesmo padrão usado por um
  banco de verdade. Recomenda-se orientar os alunos a não reutilizar
  uma senha pessoal importante aqui.

---

## Custos — por que fica de graça

- **Supabase free tier:** 500MB de banco de dados e 50.000 usuários
  autenticados por mês — muito acima do que uma escola com algumas
  turmas de professores logando precisa.
- **GitHub Pages:** hospedagem de site estático ilimitada e gratuita
  para repositórios públicos (e também para privados, em contas
  gratuitas, dentro de limites generosos de tráfego).

Nenhum cartão de crédito é exigido em nenhuma das duas etapas.
