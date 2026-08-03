-- =====================================================================
-- BANCO WL — Migração: Atribuição unificada de pacotes (inclui Básico)
-- =====================================================================
-- Até aqui, o Pacote Básico era aplicado a TODOS automaticamente, "por
-- baixo dos panos", sem aparecer como uma atribuição de verdade. Esta
-- migração unifica o modelo: o Básico passa a ser atribuído pela mesma
-- tabela `conta_pacotes` usada pelos personalizados — o que permite
-- aplicá-lo (ou qualquer outro pacote) a um aluno individual, a uma
-- turma inteira, ou à escola toda, pela mesma tela.
--
-- Para não quebrar nada que já existe:
--   • Todo aluno que já tem conta recebe automaticamente uma atribuição
--     do Básico (retroativa à data de criação da conta).
--   • Todo aluno NOVO passa a receber o Básico automaticamente no
--     cadastro (o professor não precisa lembrar de atribuir).
--   • O professor continua podendo remover o Básico de um aluno
--     específico, se quiser (ex: caso especial), ou reatribuí-lo.
--
-- COMO USAR: rode este arquivo no SQL Editor do Supabase depois de já
-- ter rodado schema.sql, migracao_pacotes_juros.sql e
-- migracao_numero_aluno.sql.
-- =====================================================================

-- =====================================================================
-- 1) BACKFILL: garante que toda conta existente já tem o Básico atribuído
-- =====================================================================
do $$
declare
  v_pacote_base_id uuid;
begin
  select id into v_pacote_base_id from pacotes_juros where tipo = 'base' limit 1;

  if v_pacote_base_id is not null then
    insert into conta_pacotes (conta_id, pacote_id, data_inicio, data_fim)
    select c.id, v_pacote_base_id, coalesce(c.criado_em::date, current_date), null
    from contas c
    where not exists (
      select 1 from conta_pacotes cp
      where cp.conta_id = c.id and cp.pacote_id = v_pacote_base_id and cp.ativo
    );
  end if;
end $$;

-- =====================================================================
-- 2) TRIGGER: todo aluno novo já nasce com o Básico atribuído
-- =====================================================================
create or replace function fn_criar_conta_para_aluno()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nova_conta_id  uuid;
  v_pacote_base_id uuid;
begin
  insert into contas (aluno_id, saldo) values (new.id, 0)
  returning id into v_nova_conta_id;

  select id into v_pacote_base_id from pacotes_juros where tipo = 'base' limit 1;
  if v_pacote_base_id is not null then
    insert into conta_pacotes (conta_id, pacote_id, data_inicio, data_fim)
    values (v_nova_conta_id, v_pacote_base_id, current_date, null);
  end if;

  return new;
end;
$$;
-- (o trigger trg_criar_conta já existente continua apontando pra esta função)

-- =====================================================================
-- 3) VIEW: taxa efetiva passa a somar SÓ as atribuições explícitas
--    (o Básico deixa de ser "somado à parte" — agora ele é só mais uma
--    linha em conta_pacotes, igual aos personalizados)
-- =====================================================================
create or replace view vw_taxa_efetiva_conta
with (security_invoker = true) as
select
  c.id as conta_id,
  c.aluno_id,
  coalesce(sum(pj.taxa_diaria) filter (
    where cp.ativo
      and cp.data_inicio <= current_date
      and (cp.data_fim is null or cp.data_fim >= current_date)
  ), 0) as taxa_total
from contas c
left join conta_pacotes cp on cp.conta_id = c.id
left join pacotes_juros pj on pj.id = cp.pacote_id
group by c.id, c.aluno_id;

-- =====================================================================
-- 4) FUNÇÃO: atribuir pacote — agora evita duplicar o mesmo pacote na
--    mesma conta (se já está ativo, substitui em vez de somar em dobro)
-- =====================================================================
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
  v_duracao  int;
  v_data_fim date;
  v_aluno_id uuid;
  v_conta_id uuid;
begin
  select duracao_dias into v_duracao from pacotes_juros where id = p_pacote_id;

  if v_duracao is not null then
    v_data_fim := p_data_inicio + v_duracao;
  else
    v_data_fim := null;
  end if;

  foreach v_aluno_id in array p_aluno_ids loop
    select c.id into v_conta_id from contas c where c.aluno_id = v_aluno_id;
    if v_conta_id is not null then
      -- desativa uma atribuição anterior do MESMO pacote nesta conta,
      -- pra evitar contar a mesma taxa em dobro se for reatribuído
      update conta_pacotes
        set ativo = false
        where conta_id = v_conta_id and pacote_id = p_pacote_id and ativo = true;

      insert into conta_pacotes (conta_id, pacote_id, data_inicio, data_fim)
      values (v_conta_id, p_pacote_id, p_data_inicio, v_data_fim);
    end if;
  end loop;
end;
$$;

-- =====================================================================
-- FIM DA MIGRAÇÃO.
-- Depois de rodar isto, atualize o index.html para a versão que permite
-- escolher o escopo (aluno individual, turma ou escola toda) e inclui o
-- Básico na lista de pacotes atribuíveis (arquivo fornecido junto).
-- =====================================================================
