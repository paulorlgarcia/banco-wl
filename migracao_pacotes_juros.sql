-- =====================================================================
-- BANCO WL — Migração: Pacotes de Juros
-- =====================================================================
-- Substitui a taxa única de rendimento por uma estrutura de PACOTES:
--   • Pacote Básico: se aplica a TODOS os alunos, sem prazo.
--   • Pacotes Personalizados: taxas extras (bônus), atribuídas a alunos
--     específicos ou turmas inteiras, por um período determinado (ou
--     sem prazo, até serem removidos manualmente).
-- O rendimento automático diário passa a somar: taxa do Básico + taxa
-- de qualquer pacote personalizado ativo naquele dia para aquela conta.
--
-- COMO USAR: rode este arquivo no SQL Editor do Supabase DEPOIS de já
-- ter rodado o schema.sql original. Pode ser executado com segurança
-- mesmo que você já tenha usado o painel por um tempo.
-- =====================================================================

-- =====================================================================
-- 1) TABELAS
-- =====================================================================

create table if not exists pacotes_juros (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  taxa_diaria   numeric(6,4) not null,
  tipo          text not null check (tipo in ('base','personalizado')),
  duracao_dias  int,          -- null = sem prazo definido
  descricao     text,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

-- Garante que só pode existir 1 pacote do tipo "base"
create unique index if not exists uq_pacote_base on pacotes_juros ((tipo)) where tipo = 'base';

-- Liga um pacote a uma conta, por um período
create table if not exists conta_pacotes (
  id            uuid primary key default gen_random_uuid(),
  conta_id      uuid not null references contas(id) on delete cascade,
  pacote_id     uuid not null references pacotes_juros(id) on delete cascade,
  data_inicio   date not null default current_date,
  data_fim      date,         -- null = sem prazo (permanece até ser removido)
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);
create index if not exists idx_conta_pacotes_conta on conta_pacotes(conta_id);

-- =====================================================================
-- 2) MIGRA A TAXA ANTIGA PARA O "PACOTE BÁSICO"
-- =====================================================================
do $$
declare
  v_taxa_antiga numeric;
begin
  if not exists (select 1 from pacotes_juros where tipo = 'base') then
    -- tenta aproveitar a taxa antiga (se a coluna ainda existir)
    begin
      execute 'select taxa_rendimento_diaria from configuracoes where id = 1'
        into v_taxa_antiga;
    exception when undefined_column then
      v_taxa_antiga := null;
    end;

    insert into pacotes_juros (nome, taxa_diaria, tipo, duracao_dias, descricao)
    values (
      'Pacote Básico',
      coalesce(v_taxa_antiga, 0.10),
      'base',
      null,
      'Taxa aplicada a todos os alunos, sem prazo.'
    );
  end if;
end $$;

-- A taxa única antiga não é mais usada — o rendimento agora vem dos pacotes.
alter table configuracoes drop column if exists taxa_rendimento_diaria;

-- =====================================================================
-- 3) TRIGGER: protege o Pacote Básico contra exclusão
-- =====================================================================
create or replace function fn_bloquear_delete_pacote_base()
returns trigger
language plpgsql
as $$
begin
  if old.tipo = 'base' then
    raise exception 'O pacote básico não pode ser excluído — apenas editado.';
  end if;
  return old;
end;
$$;

drop trigger if exists trg_bloquear_delete_pacote_base on pacotes_juros;
create trigger trg_bloquear_delete_pacote_base
before delete on pacotes_juros
for each row execute function fn_bloquear_delete_pacote_base();

-- =====================================================================
-- 4) VIEWS — taxa efetiva por conta e pacotes ativos por conta
-- =====================================================================

create or replace view vw_taxa_efetiva_conta
with (security_invoker = true) as
select
  c.id as conta_id,
  c.aluno_id,
  coalesce(pb.taxa_diaria, 0) as taxa_base,
  coalesce(sum(pp.taxa_diaria) filter (
    where cp.ativo
      and cp.data_inicio <= current_date
      and (cp.data_fim is null or cp.data_fim >= current_date)
  ), 0) as taxa_bonus,
  coalesce(pb.taxa_diaria, 0) + coalesce(sum(pp.taxa_diaria) filter (
    where cp.ativo
      and cp.data_inicio <= current_date
      and (cp.data_fim is null or cp.data_fim >= current_date)
  ), 0) as taxa_total
from contas c
left join pacotes_juros pb on pb.tipo = 'base'
left join conta_pacotes cp on cp.conta_id = c.id
left join pacotes_juros pp on pp.id = cp.pacote_id and pp.tipo = 'personalizado'
group by c.id, c.aluno_id, pb.taxa_diaria;

create or replace view vw_pacotes_ativos_conta
with (security_invoker = true) as
select
  cp.id as conta_pacote_id,
  cp.conta_id,
  cp.data_inicio,
  cp.data_fim,
  pj.id as pacote_id,
  pj.nome,
  pj.taxa_diaria
from conta_pacotes cp
join pacotes_juros pj on pj.id = cp.pacote_id
where cp.ativo
  and cp.data_inicio <= current_date
  and (cp.data_fim is null or cp.data_fim >= current_date);

-- =====================================================================
-- 5) FUNÇÃO: rendimento automático (agora baseado em pacotes)
-- =====================================================================
create or replace function fn_aplicar_rendimento_automatico()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ativo boolean;
  r record;
  v_juros numeric;
begin
  select rendimento_automatico_ativo into v_ativo from configuracoes where id = 1;
  if not v_ativo then
    return;
  end if;

  for r in
    select c.id as conta_id, c.saldo, v.taxa_total
    from contas c
    join vw_taxa_efetiva_conta v on v.conta_id = c.id
    where c.saldo > 0 and v.taxa_total > 0
  loop
    v_juros := round(r.saldo * (r.taxa_total / 100), 2);
    if v_juros > 0 then
      update contas set saldo = saldo + v_juros where id = r.conta_id;
      insert into transacoes (conta_id, tipo, valor, saldo_apos, descricao, professor_email)
      values (
        r.conta_id, 'rendimento_automatico', v_juros, r.saldo + v_juros,
        'Rendimento diário automático (' || r.taxa_total || '%)', 'sistema'
      );
    end if;
  end loop;
end;
$$;

-- =====================================================================
-- 6) FUNÇÕES: atribuir e remover pacote de uma conta
-- =====================================================================

-- Atribui um pacote a uma lista de alunos, calculando a data final
-- automaticamente a partir da duração do pacote (se houver).
create or replace function fn_atribuir_pacote(
  p_pacote_id uuid,
  p_aluno_ids uuid[],
  p_data_inicio date default current_date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duracao int;
  v_data_fim date;
  v_aluno_id uuid;
begin
  select duracao_dias into v_duracao from pacotes_juros where id = p_pacote_id;

  if v_duracao is not null then
    v_data_fim := p_data_inicio + v_duracao;
  else
    v_data_fim := null;
  end if;

  foreach v_aluno_id in array p_aluno_ids loop
    insert into conta_pacotes (conta_id, pacote_id, data_inicio, data_fim)
    select c.id, p_pacote_id, p_data_inicio, v_data_fim
    from contas c where c.aluno_id = v_aluno_id;
  end loop;
end;
$$;

-- Remove (desativa) um pacote atribuído a uma conta antes do prazo
create or replace function fn_remover_pacote_conta(p_conta_pacote_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update conta_pacotes set ativo = false where id = p_conta_pacote_id;
end;
$$;

-- =====================================================================
-- 7) SEGURANÇA
-- =====================================================================
alter table pacotes_juros  enable row level security;
alter table conta_pacotes  enable row level security;

drop policy if exists "professores_acesso_total" on pacotes_juros;
create policy "professores_acesso_total" on pacotes_juros
  for all to authenticated using (true) with check (true);

drop policy if exists "professores_acesso_total" on conta_pacotes;
create policy "professores_acesso_total" on conta_pacotes
  for all to authenticated using (true) with check (true);

grant select, insert, update, delete on pacotes_juros, conta_pacotes to authenticated;
grant select on vw_taxa_efetiva_conta, vw_pacotes_ativos_conta to authenticated;

revoke all on function fn_atribuir_pacote(uuid, uuid[], date) from public;
revoke all on function fn_remover_pacote_conta(uuid) from public;
grant execute on function fn_atribuir_pacote(uuid, uuid[], date) to authenticated;
grant execute on function fn_remover_pacote_conta(uuid) to authenticated;

-- =====================================================================
-- FIM DA MIGRAÇÃO.
-- Depois de rodar isto, atualize o index.html para a versão com a tela
-- de Configurações (arquivo fornecido junto).
-- =====================================================================
