export type MergeMethod = 'mergeCommit' | 'squash' | 'rebase'
export type PermissionDecision = 'allow' | 'deny'

export type ChatAttachment =
  | { image: { id: string; mediaType: string; fileName: string; data: string } }
  | { pastedText: { id: string; index: number; text: string } }

export interface DiffInfo {
  paths: string[]
  added: number
  deleted: number
}

export interface Sender {
  send<T>(name: string, args: unknown): Promise<T>
}

export function commands(sender: Sender) {
  return {
    sendChat: (chatID: number, text: string, attachments: ChatAttachment[] = []) =>
      sender.send<Record<string, never>>('chat.send', { chatID, text, attachments }),
    approveSpec: (chatID: number) => sender.send<number>('chat.approveSpec', { chatID }),
    markViewed: (chatID: number) => sender.send<Record<string, never>>('chat.markViewed', { chatID }),
    answerQuestion: (requestID: number, text: string) => sender.send<Record<string, never>>('approval.answerQuestion', { requestID, text }),
    answerPermission: (decision: PermissionDecision, ids: { permissionRequestID?: number; chatRequestID?: number }) =>
      sender.send<Record<string, never>>('approval.answerPermission', { ...ids, decision }),
    resolveApproval: (runID: number, approved: boolean, note?: string, requestID?: number) =>
      sender.send<Record<string, never>>('run.resolveApproval', {
        runID, approved, ...(note ? { note } : {}), ...(requestID !== undefined ? { requestID } : {}),
      }),
    merge: (runID: number, method: MergeMethod = 'mergeCommit') => sender.send<Record<string, never>>('run.merge', { runID, method }),
    push: (runID: number) => sender.send<string>('run.push', { runID }),
    diffSummary: (runID: number) => sender.send<DiffInfo>('run.diffSummary', { runID }),
  }
}

export type Commands = ReturnType<typeof commands>
