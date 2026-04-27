export function releaseIfPresent(resource) {
  resource?.release?.();
}

export function deleteGlProgramIfPresent(glContext, program) {
  if (!glContext || !program) {
    return;
  }

  glContext.deleteProgram(program);
}
