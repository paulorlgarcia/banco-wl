-- =====================================================================
-- BANCO WL — Schema do banco de dados (Supabase / PostgreSQL)
-- =====================================================================
-- Este arquivo cria toda a estrutura do Banco WL: turmas, alunos, contas,
-- transações, configurações de rendimento e as regras de segurança que
-- garantem que SOMENTE professores autenticados (logados) têm acesso.
-- Alunos nunca fazem login neste sistema — eles não têm nenhuma conta
-- de usuário, portanto não têm nenhum acesso, direto ou indireto.
--
-- COMO USAR:
-- 1. Crie um projeto gratuito em https://supabase.com
-- 2. Abra o "SQL Editor" do seu projeto
-- 3. Cole este arquivo inteiro e clique em "Run"
-- =====================================================================


-- =====================================================================
-- 1) EXTENSÕES NECESSÁRIAS
-- =====================================================================
create extension if not exists pgcrypto;   -- geração de UUIDs
create extension if not exists pg_cron;    -- agendamento do rendimento diário


-- =====================================================================
-- 2) TABELAS
-- =====================================================================

-- Turmas (ex: 6ºA, 7ºB)
create table if not exists turmas (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null unique,
  criado_em  timestamptz not null default now()
);

-- Alunos (cada aluno pertence a exatamente uma turma)
create table if not exists alunos (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  turma_id   uuid not null references turmas(id) on delete restrict,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- Contas (1 conta por aluno, criada automaticamente — ver trigger abaixo)
create table if not exists contas (
  id         uuid primary key default gen_random_uuid(),
  aluno_id   uuid not null unique references alunos(id) on delete cascade,
  saldo      numeric(12,2) not null default 0 check (saldo >= 0),
  criado_em  timestamptz not null default now()
);

-- Transações (extrato completo, nunca é apagado — histórico permanente)
create table if not exists transacoes (
  id                 uuid primary key default gen_random_uuid(),
  conta_id           uuid not null references contas(id) on delete cascade,
  tipo               text not null check (tipo in (
                       'deposito',
                       'saque',
                       'transferencia_enviada',
                       'transferencia_recebida',
                       'rendimento_automatico',
                       'rendimento_manual'
                     )),
  valor              numeric(12,2) not null,
  saldo_apos         numeric(12,2) not null,
  descricao          text,
  transacao_par_id   uuid references transacoes(id),  -- liga as 2 pontas de uma transferência
  professor_email    text,
  criado_em          timestamptz not null default now()
);
create index if not exists idx_transacoes_conta on transacoes(conta_id, criado_em desc);

-- Configurações do rendimento (linha única, id sempre = 1)
create table if not exists configuracoes (
  id                            int primary key default 1,
  taxa_rendimento_diaria        numeric(6,4) not null default 0.10, -- em %, ex: 0.10 = 0,10% ao dia
  rendimento_automatico_ativo   boolean not null default true,
  check (id = 1)
);
insert into configuracoes (id) values (1) on conflict (id) do nothing;


-- =====================================================================
-- 3) TRIGGER: cria a conta automaticamente quando um aluno é cadastrado
-- =====================================================================
create or replace function fn_criar_conta_para_aluno()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into contas (aluno_id, saldo) values (new.id, 0);
  return new;
end;
$$;

drop trigger if exists trg_criar_conta on alunos;
create trigger trg_criar_conta
after insert on alunos
for each row execute function fn_criar_conta_para_aluno();


-- =====================================================================
-- 4) FUNÇÕES TRANSACIONAIS (chamadas pelo painel via RPC)
-- =====================================================================

-- DEPOSITAR
create or replace function fn_depositar(p_aluno_id uuid, p_valor numeric, p_descricao text default null)
returns contas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conta contas;
  v_email text := coalesce(auth.jwt() ->> 'email', 'sistema');
begin
  if p_valor <= 0 then
    raise exception 'O valor do depósito deve ser maior que zero';
  end if;

  update contas set saldo = saldo + p_valor
  where aluno_id = p_aluno_id
  returning * into v_conta;

  if not found then
    raise exception 'Conta não encontrada para este aluno';
  end if;

  insert into transacoes (conta_id, tipo, valor, saldo_apos, descricao, professor_email)
  values (v_conta.id, 'deposito', p_valor, v_conta.saldo, p_descricao, v_email);

  return v_conta;
end;
$$;

-- SACAR
create or replace function fn_sacar(p_aluno_id uuid, p_valor numeric, p_descricao text default null)
returns contas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conta contas;
  v_email text := coalesce(auth.jwt() ->> 'email', 'sistema');
begin
  if p_valor <= 0 then
    raise exception 'O valor do saque deve ser maior que zero';
  end if;

  select * into v_conta from contas where aluno_id = p_aluno_id for update;
  if not found then
    raise exception 'Conta não encontrada para este aluno';
  end if;

  if v_conta.saldo < p_valor then
    raise exception 'Saldo insuficiente. Saldo atual: %', v_conta.saldo;
  end if;

  update contas set saldo = saldo - p_valor
  where aluno_id = p_aluno_id
  returning * into v_conta;

  insert into transacoes (conta_id, tipo, valor, saldo_apos, descricao, professor_email)
  values (v_conta.id, 'saque', p_valor, v_conta.saldo, p_descricao, v_email);

  return v_conta;
end;
$$;

-- TRANSFERIR (entre dois alunos)
create or replace function fn_transferir(p_aluno_origem_id uuid, p_aluno_destino_id uuid, p_valor numeric, p_descricao text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conta_origem  contas;
  v_conta_destino contas;
  v_email text := coalesce(auth.jwt() ->> 'email', 'sistema');
  v_tx_saida uuid;
begin
  if p_valor <= 0 then
    raise exception 'O valor da transferência deve ser maior que zero';
  end if;

  if p_aluno_origem_id = p_aluno_destino_id then
    raise exception 'Não é possível transferir para a mesma conta';
  end if;

  select * into v_conta_origem from contas where aluno_id = p_aluno_origem_id for update;
  if not found then
    raise exception 'Conta de origem não encontrada';
  end if;

  if v_conta_origem.saldo < p_valor then
    raise exception 'Saldo insuficiente na conta de origem. Saldo atual: %', v_conta_origem.saldo;
  end if;

  select * into v_conta_destino from contas where aluno_id = p_aluno_destino_id for update;
  if not found then
    raise exception 'Conta de destino não encontrada';
  end if;

  update contas set saldo = saldo - p_valor where id = v_conta_origem.id
  returning * into v_conta_origem;

  insert into transacoes (conta_id, tipo, valor, saldo_apos, descricao, professor_email)
  values (v_conta_origem.id, 'transferencia_enviada', p_valor, v_conta_origem.saldo, p_descricao, v_email)
  returning id into v_tx_saida;

  update contas set saldo = saldo + p_valor where id = v_conta_destino.id
  returning * into v_conta_destino;

  insert into transacoes (conta_id, tipo, valor, saldo_apos, descricao, professor_email, transacao_par_id)
  values (v_conta_destino.id, 'transferencia_recebida', p_valor, v_conta_destino.saldo, p_descricao, v_email, v_tx_saida);
end;
$$;


-- =====================================================================
-- 5) RENDIMENTO (opção híbrida: automático diário + manual sob demanda)
-- =====================================================================

-- Automático: roda sozinho todo dia via pg_cron, usando a taxa configurada
create or replace function fn_aplicar_rendimento_automatico()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_taxa   numeric;
  v_ativo  boolean;
  r        record;
  v_juros  numeric;
begin
  select taxa_rendimento_diaria, rendimento_automatico_ativo
  into v_taxa, v_ativo
  from configuracoes where id = 1;

  if not v_ativo or v_taxa <= 0 then
    return;
  end if;

  for r in select * from contas where saldo > 0 loop
    v_juros := round(r.saldo * (v_taxa / 100), 2);
    if v_juros > 0 then
      update contas set saldo = saldo + v_juros where id = r.id;
      insert into transacoes (conta_id, tipo, valor, saldo_apos, descricao, professor_email)
      values (r.id, 'rendimento_automatico', v_juros, r.saldo + v_juros,
              'Rendimento diário automático (' || v_taxa || '%)', 'sistema');
    end if;
  end loop;
end;
$$;

-- Agenda a execução automática todo dia às 03:00 (horário do servidor, UTC)
select cron.schedule(
  'rendimento-diario-banco-wl',
  '0 3 * * *',
  $$select fn_aplicar_rendimento_automatico();$$
);

-- Manual: o professor aplica uma taxa extra na hora, para todos os alunos
-- ou só para uma turma específica (ex: bônus de uma atividade)
create or replace function fn_aplicar_rendimento_manual(
  p_taxa numeric,
  p_turma_id uuid default null,
  p_descricao text default 'Rendimento manual aplicado pelo professor'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := coalesce(auth.jwt() ->> 'email', 'sistema');
  r        record;
  v_juros  numeric;
  v_novo_saldo numeric;
begin
  if p_taxa = 0 then
    raise exception 'Informe uma taxa diferente de zero';
  end if;

  for r in
    select c.* from contas c
    join alunos a on a.id = c.aluno_id
    where c.saldo > 0
      and (p_turma_id is null or a.turma_id = p_turma_id)
  loop
    v_juros := round(r.saldo * (p_taxa / 100), 2);
    if v_juros <> 0 then
      update contas set saldo = greatest(saldo + v_juros, 0) where id = r.id
      returning saldo into v_novo_saldo;

      insert into transacoes (conta_id, tipo, valor, saldo_apos, descricao, professor_email)
      values (r.id, 'rendimento_manual', v_juros, v_novo_saldo, p_descricao, v_email);
    end if;
  end loop;
end;
$$;


-- =====================================================================
-- 6) VIEWS DE APOIO (extrato legível e resumo por turma)
-- =====================================================================

create or replace view vw_extrato
with (security_invoker = true) as
select
  t.id, t.tipo, t.valor, t.saldo_apos, t.descricao, t.professor_email, t.criado_em,
  a.nome  as aluno_nome,
  tu.nome as turma_nome,
  a.id    as aluno_id
from transacoes t
join contas  c  on c.id = t.conta_id
join alunos  a  on a.id = c.aluno_id
join turmas  tu on tu.id = a.turma_id;

create or replace view vw_resumo_turma
with (security_invoker = true) as
select
  tu.id as turma_id,
  tu.nome as turma_nome,
  count(a.id) as total_alunos,
  coalesce(sum(c.saldo), 0) as saldo_total
from turmas tu
left join alunos a on a.turma_id = tu.id
left join contas c on c.aluno_id = a.id
group by tu.id, tu.nome;


-- =====================================================================
-- 7) SEGURANÇA: Row Level Security — só professores autenticados
-- =====================================================================
-- Não existe cadastro de aluno como usuário. O papel "authenticated" do
-- Supabase, neste sistema, É o professor. O papel "anon" (não logado)
-- não recebe nenhuma permissão — portanto alunos, que nunca fazem login,
-- não conseguem ler nem escrever absolutamente nada.

alter table turmas         enable row level security;
alter table alunos         enable row level security;
alter table contas         enable row level security;
alter table transacoes     enable row level security;
alter table configuracoes  enable row level security;

create policy "professores_acesso_total" on turmas
  for all to authenticated using (true) with check (true);

create policy "professores_acesso_total" on alunos
  for all to authenticated using (true) with check (true);

create policy "professores_acesso_total" on contas
  for all to authenticated using (true) with check (true);

create policy "professores_acesso_total" on transacoes
  for all to authenticated using (true) with check (true);

create policy "professores_acesso_total" on configuracoes
  for all to authenticated using (true) with check (true);

-- Concede as permissões básicas de tabela apenas para o papel "authenticated".
-- Note que NÃO há nenhum "grant ... to anon" em lugar nenhum deste arquivo.
grant usage on schema public to authenticated;
grant select, insert, update, delete on turmas, alunos, contas, transacoes to authenticated;
grant select, update on configuracoes to authenticated;
grant select on vw_extrato, vw_resumo_turma to authenticated;

-- Só professores autenticados podem executar as funções de transação.
revoke all on function fn_depositar(uuid, numeric, text) from public;
revoke all on function fn_sacar(uuid, numeric, text) from public;
revoke all on function fn_transferir(uuid, uuid, numeric, text) from public;
revoke all on function fn_aplicar_rendimento_manual(numeric, uuid, text) from public;

grant execute on function fn_depositar(uuid, numeric, text) to authenticated;
grant execute on function fn_sacar(uuid, numeric, text) to authenticated;
grant execute on function fn_transferir(uuid, uuid, numeric, text) to authenticated;
grant execute on function fn_aplicar_rendimento_manual(numeric, uuid, text) to authenticated;

-- fn_aplicar_rendimento_automatico só é chamada pelo cron (não precisa ser
-- exposta a ninguém), então não recebe nenhum grant de execução.

-- =====================================================================
-- FIM DO SCHEMA — pronto para uso.
-- Próximo passo: cadastre os professores em Authentication > Users no
-- painel do Supabase (e-mail + senha). Eles serão os únicos com login.
-- =====================================================================
