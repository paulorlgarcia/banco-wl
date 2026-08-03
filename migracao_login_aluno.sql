-- =====================================================================
-- BANCO WL — Migração: Login de consulta para o aluno (RA + senha)
-- =====================================================================
-- Adiciona ao aluno um RA (registro do aluno, único na escola) e uma
-- senha (guardada sempre como hash — nunca em texto puro). Cria uma
-- função de login que devolve, SOMENTE se RA+senha baterem, os dados
-- daquele aluno: saldo, taxa de juros, pacotes ativos e extrato.
--
-- IMPORTANTE — por que isso é diferente do login do professor:
-- O aluno NÃO ganha uma conta de autenticação do Supabase. Ele nunca
-- vira "authenticated" nem tem acesso direto a nenhuma tabela. Em vez
-- disso, ele chama uma única função (fn_login_aluno) que, por dentro,
-- confere a senha e devolve só os dados da própria conta, já prontos.
-- Isso evita precisar de uma chave mestra (service role) no site
-- estático — o que seria um risco de segurança sério.
--
-- COMO USAR: rode este arquivo no SQL Editor do Supabase depois de já
-- ter rodado os arquivos anteriores (schema.sql e as migrações de
-- pacotes/número).
-- =====================================================================

-- =====================================================================
-- 1) COLUNAS NOVAS
-- =====================================================================
alter table alunos add column if not exists ra text;
alter table alunos add column if not exists senha_hash text;

-- RA é único na escola inteira (diferente do "número", que só é único
-- dentro da turma)
create unique index if not exists uq_aluno_ra on alunos (ra) where ra is not null;

-- =====================================================================
-- 2) FUNÇÃO: professor define/reseta a senha de um aluno
-- =====================================================================
create or replace function fn_definir_senha_aluno(p_aluno_id uuid, p_senha text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_senha is null or length(p_senha) < 4 then
    raise exception 'A senha deve ter ao menos 4 caracteres';
  end if;

  update alunos
    set senha_hash = crypt(p_senha, gen_salt('bf'))
    where id = p_aluno_id;

  if not found then
    raise exception 'Aluno não encontrado';
  end if;
end;
$$;

-- =====================================================================
-- 3) FUNÇÃO: login do aluno (RA + senha) — devolve só os dados da
--    própria conta: saldo, taxa efetiva, pacotes ativos e extrato
-- =====================================================================
create or replace function fn_login_aluno(p_ra text, p_senha text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_aluno   alunos;
  v_conta   contas;
  v_taxa    numeric;
  v_pacotes jsonb;
  v_extrato jsonb;
begin
  select * into v_aluno from alunos where ra = p_ra and ativo;

  if not found
     or v_aluno.senha_hash is null
     or v_aluno.senha_hash <> crypt(p_senha, v_aluno.senha_hash) then
    raise exception 'RA ou senha inválidos';
  end if;

  select * into v_conta from contas where aluno_id = v_aluno.id;

  select coalesce(taxa_total, 0) into v_taxa
  from vw_taxa_efetiva_conta where conta_id = v_conta.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'nome', nome,
           'taxa_diaria', taxa_diaria,
           'data_inicio', data_inicio,
           'data_fim', data_fim
         ) order by data_inicio), '[]'::jsonb)
    into v_pacotes
    from vw_pacotes_ativos_conta
    where conta_id = v_conta.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'tipo', tipo,
           'valor', valor,
           'saldo_apos', saldo_apos,
           'descricao', descricao,
           'criado_em', criado_em
         ) order by criado_em desc), '[]'::jsonb)
    into v_extrato
    from (
      select * from transacoes
      where conta_id = v_conta.id
      order by criado_em desc
      limit 100
    ) t;

  return jsonb_build_object(
    'aluno', jsonb_build_object('nome', v_aluno.nome, 'numero', v_aluno.numero, 'ra', v_aluno.ra),
    'turma', (select nome from turmas where id = v_aluno.turma_id),
    'saldo', v_conta.saldo,
    'taxa_diaria_total', v_taxa,
    'pacotes_ativos', v_pacotes,
    'extrato', v_extrato
  );
end;
$$;

-- =====================================================================
-- 4) PERMISSÕES
-- =====================================================================
-- fn_definir_senha_aluno: só professores (authenticated) podem chamar
revoke all on function fn_definir_senha_aluno(uuid, text) from public;
grant execute on function fn_definir_senha_aluno(uuid, text) to authenticated;

-- fn_login_aluno: o ALUNO chama isso sem estar logado (papel "anon"),
-- por isso ela precisa estar liberada pra "anon" — mas ela é a ÚNICA
-- porta de entrada; nenhuma tabela continua liberada para "anon".
revoke all on function fn_login_aluno(text, text) from public;
grant execute on function fn_login_aluno(text, text) to anon, authenticated;

-- =====================================================================
-- FIM DA MIGRAÇÃO.
-- Depois de rodar isto:
--   • No index.html (painel do professor), cadastre o RA de cada aluno
--     e defina uma senha inicial pela ação "Senha" na linha do aluno.
--   • Publique o aluno.html (fornecido junto) como a página que os
--     alunos vão acessar para consultar extrato, juros e pacotes.
-- =====================================================================
