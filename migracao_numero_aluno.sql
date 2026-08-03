-- =====================================================================
-- BANCO WL — Migração: Número do aluno
-- =====================================================================
-- Adiciona o campo "número" (ex: número de chamada) ao cadastro do
-- aluno. É único dentro de cada turma (dois alunos da mesma turma não
-- podem ter o mesmo número), mas pode se repetir entre turmas diferentes
-- (ex: o "nº 5" do 6ºA e o "nº 5" do 7ºB não conflitam).
-- =====================================================================

alter table alunos add column if not exists numero integer;

-- Garante que o número não se repete dentro da mesma turma (ignora nulos)
create unique index if not exists uq_aluno_numero_por_turma
  on alunos (turma_id, numero) where numero is not null;

-- =====================================================================
-- FIM DA MIGRAÇÃO.
-- Depois de rodar isto, atualize o index.html para a versão com o
-- campo de número (arquivo fornecido junto).
-- =====================================================================
