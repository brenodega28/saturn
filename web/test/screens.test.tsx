import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it } from 'vitest'
import { useApp } from '../src/store'
import type { FixtureServer } from './fixtureServer'
import { upsert } from './fixtureServer'
import { renderApp, startFixture } from './helpers'

let server: FixtureServer | undefined

afterEach(async () => {
  await server?.stop()
  server = undefined
})

function lastCommand(name: string) {
  return server!.commands.filter((command) => command.name === name).at(-1)
}

describe('Chats drawer', () => {
  it('groups chats into Needs you, In progress, Not started and Finished', async () => {
    server = await startFixture()
    await renderApp(server)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Open chats' }))
    const drawer = screen.getByRole('navigation', { name: 'Chats' })
    const group = (name: string) => within(drawer).getByRole('region', { name })
    const titles = (name: string) => within(group(name)).queryAllByRole('button', { name: /,/ }).map((row) => row.querySelector('.name')!.textContent)
    expect(titles('Needs you')).toEqual(['Hamburger menu for mobile', 'Rate-limit the public API before the launch', 'Add a CHANGELOG entry for 2.4', 'Let’s work on phase 1'])
    expect(titles('In progress')).toEqual(['Check the deploy script on the build box'])
    expect(titles('Not started')).toEqual(['Verify if there’s an e2e test for the complete flow', 'Analyze t3code and list what we could borrow'])
    const finished = within(group('Finished')).getByRole('button', { name: /Finished/ })
    expect(finished).toHaveAttribute('aria-expanded', 'false')
    await user.click(finished)
    expect(titles('Finished')).toEqual(['Given the new pricing table, update the checkout copy', 'Try a WebGL renderer'])
    expect(within(drawer).getByText('$4.15')).toBeInTheDocument()
  })

  it('filters by search and by project chip, and opens a tapped chat', async () => {
    server = await startFixture()
    await renderApp(server)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Open chats' }))
    const drawer = screen.getByRole('navigation', { name: 'Chats' })
    await user.click(within(drawer).getByRole('button', { name: 'ensemble' }))
    expect(within(drawer).getByRole('button', { name: 'ensemble' })).toHaveAttribute('aria-pressed', 'true')
    const rows = () => within(drawer).queryAllByRole('button', { name: /, (Needs you|Stuck|Building|In review|Open|Finished|Closed)/ }).map((row) => row.querySelector('.name')!.textContent)
    expect(rows()).toEqual(['Check the deploy script on the build box', 'Analyze t3code and list what we could borrow'])
    await user.click(within(drawer).getByRole('button', { name: 'All projects' }))
    await user.type(within(drawer).getByRole('searchbox', { name: 'Search chats and projects' }), 'rate-limit')
    expect(rows()).toEqual(['Rate-limit the public API before the launch'])
    await user.click(within(drawer).getByRole('button', { name: /Rate-limit the public API/ }))
    expect(screen.queryByRole('navigation', { name: 'Chats' })).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Rate-limit the public API before the launch' })).toBeInTheDocument()
    await waitFor(() => expect(lastCommand('chat.markViewed')?.args).toEqual({ chatID: 1 }))
  })
})

describe('Chat screen', () => {
  it('renders the header, Lead messages, spec card, events, review card and composer line', async () => {
    server = await startFixture()
    await renderApp(server)
    const header = screen.getByRole('banner')
    expect(within(header).getByRole('heading', { name: 'Hamburger menu for mobile' })).toBeInTheDocument()
    expect(within(header).getByRole('img', { name: 'Needs you' })).toBeInTheDocument()
    expect(within(header).getByText(/monorepo · This Mac/)).toBeInTheDocument()
    expect(within(header).getByText('$4.15')).toBeInTheDocument()
    expect(within(header).getByRole('img', { name: /4 chats need you/ })).toBeInTheDocument()

    const log = screen.getByRole('log', { name: 'Chat with the Lead' })
    expect(within(log).getByText('In mobile, create a hamburger icon with animation that opens a menu')).toBeInTheDocument()
    expect(within(log).getByText('One task for Front-end Dev, then a review. You approved the spec.')).toBeInTheDocument()
    const spec = within(log).getByRole('region', { name: /Spec Hamburger menu/ })
    expect(within(spec).getByText('Approved')).toBeInTheDocument()
    expect(within(spec).getByText('3 acceptance criteria')).toBeInTheDocument()
    expect(within(log).getByRole('button', { name: /Front-end Dev · Build/ })).toHaveTextContent('Built the menu and the focus trap')
    expect(within(log).getByRole('button', { name: /Reviewer · Review/ })).toBeInTheDocument()

    const review = within(log).getByRole('region', { name: 'Ready for your review' })
    expect(within(review).getByText(/Focus is trapped while it’s open/)).toBeInTheDocument()
    await waitFor(() => expect(within(review).getByLabelText('186 lines added, 24 removed')).toBeInTheDocument())
    expect(within(review).getByText('7 files')).toBeInTheDocument()
    expect(within(review).getByText('checks 5/5 ✓')).toBeInTheDocument()
    expect(within(log).queryByRole('region', { name: 'Approval' })).not.toBeInTheDocument()

    expect(screen.getByText('Feature delivery')).toBeInTheDocument()
    expect(screen.getByText('Opus · Medium')).toBeInTheDocument()
  })

  it('shows a typing line while a worker runs', async () => {
    server = await startFixture()
    await renderApp(server, 4)
    expect(screen.getByRole('status')).toHaveTextContent('Claude Code is working on read the deploy script and list what breaks')
  })

  it('sends a message with chat.send and streams the reply in', async () => {
    server = await startFixture({
      'chat.send': (args, fixture) => {
        fixture.pushChanges([upsert('leadMessage', 600, { projectId: 1, taskId: 3, kind: 'user', text: args.text, createdAt: '2026-11-25 15:00:00.000' })])
        setTimeout(() => fixture.pushChanges([upsert('leadMessage', 601, { projectId: 1, taskId: 3, kind: 'lead', text: 'On it. I’ll ask the Reviewer to look again.', createdAt: '2026-11-25 15:00:05.000' })]), 30)
        return {}
      },
    })
    await renderApp(server)
    const user = userEvent.setup()
    const box = screen.getByRole('textbox', { name: 'Message the Lead' })
    expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled()
    await user.type(box, 'Make the icon a bit larger')
    await user.click(screen.getByRole('button', { name: 'Send' }))
    await waitFor(() => expect(lastCommand('chat.send')?.args).toEqual({ chatID: 3, text: 'Make the icon a bit larger', attachments: [] }))
    expect(await screen.findByText('Make the icon a bit larger', { selector: '.bubble' })).toBeInTheDocument()
    expect(await screen.findByText('On it. I’ll ask the Reviewer to look again.')).toBeInTheDocument()
    expect(box).toHaveValue('')
  })

  it('answers a Lead question with an option', async () => {
    server = await startFixture({
      'approval.answerQuestion': (args, fixture) => {
        fixture.pushChanges([upsert('chatRequest', 11, {
          projectId: 1, taskId: 1, agentId: 1, kind: 'question', title: 'How strict should the limit be?', body: '', status: 'answered', response: args.text,
          questions: '[{"question":"Which limit should anonymous clients get?","options":["60 per minute","600 per hour"]}]', createdAt: '2026-11-25 13:40:00.000',
        })])
        return {}
      },
    })
    await renderApp(server, 1)
    const user = userEvent.setup()
    const card = screen.getByRole('region', { name: 'Question from the Lead' })
    expect(within(card).getByText('Which limit should anonymous clients get?')).toBeInTheDocument()
    await user.click(within(card).getByRole('button', { name: '60 per minute' }))
    await waitFor(() => expect(lastCommand('approval.answerQuestion')?.args).toEqual({ requestID: 11, text: '60 per minute' }))
    expect(await within(card).findByText('You answered: 60 per minute')).toBeInTheDocument()
  })

  it('answers a permission prompt', async () => {
    server = await startFixture({ 'approval.answerPermission': () => ({}) })
    await renderApp(server, 9)
    const user = userEvent.setup()
    const card = screen.getByRole('region', { name: 'Permission request' })
    await user.click(within(card).getByRole('button', { name: 'Allow' }))
    await waitFor(() => expect(lastCommand('approval.answerPermission')?.args).toEqual({ permissionRequestID: 5, decision: 'allow' }))
  })

  it('approves a spec with chat.approveSpec and reads it', async () => {
    server = await startFixture({ 'chat.approveSpec': () => 12 })
    await renderApp(server, 5)
    const user = userEvent.setup()
    const spec = screen.getByRole('region', { name: /Spec E2E coverage check/ })
    expect(within(spec).getByText('Needs approval')).toBeInTheDocument()
    await user.click(within(spec).getByRole('button', { name: 'Read spec' }))
    expect(await within(spec).findByText(/A read-only spec/)).toBeInTheDocument()
    await user.click(within(spec).getByRole('button', { name: 'Approve & start' }))
    await waitFor(() => expect(lastCommand('chat.approveSpec')?.args).toEqual({ chatID: 5 }))
  })

  it('shows a command failure, including forbidden', async () => {
    server = await startFixture({ 'chat.approveSpec': () => ({ error: { code: 'forbidden', message: 'Remote devices can’t run chat.approveSpec.' } }) })
    await renderApp(server, 5)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Approve & start' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t approve the spec: Remote devices can’t run chat.approveSpec.')
  })
})

describe('Review changes', () => {
  it('lists the changed files and approves the run', async () => {
    server = await startFixture({ 'run.resolveApproval': () => ({}) })
    await renderApp(server)
    const user = userEvent.setup()
    await user.click(within(screen.getByRole('region', { name: 'Ready for your review' })).getByRole('button', { name: 'Review changes' }))
    const sheet = screen.getByRole('dialog', { name: 'Review changes' })
    await waitFor(() => expect(within(sheet).getAllByRole('listitem')).toHaveLength(7))
    expect(within(sheet).getByText('src/MobileMenu.tsx')).toBeInTheDocument()
    expect(within(sheet).getByText('5 of 5 passed')).toBeInTheDocument()
    await user.click(within(sheet).getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(lastCommand('run.resolveApproval')?.args).toEqual({ runID: 3, approved: true, requestID: 31 }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
  })

  it('requests changes with a note', async () => {
    server = await startFixture({ 'run.resolveApproval': () => ({}) })
    await renderApp(server)
    const user = userEvent.setup()
    await user.click(within(screen.getByRole('region', { name: 'Ready for your review' })).getByRole('button', { name: 'Review changes' }))
    const sheet = screen.getByRole('dialog', { name: 'Review changes' })
    await user.click(within(sheet).getByRole('button', { name: 'Request changes' }))
    await user.type(within(sheet).getByRole('textbox', { name: 'What should change?' }), 'Animate the X faster')
    await user.click(within(sheet).getByRole('button', { name: 'Send' }))
    await waitFor(() => expect(lastCommand('run.resolveApproval')?.args).toEqual({ runID: 3, approved: false, note: 'Animate the X faster', requestID: 31 }))
  })
})

describe('Details drawer', () => {
  it('shows the Task tab: stages, branch, app runner, changes, checks and workers', async () => {
    server = await startFixture()
    await renderApp(server)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Open task details' }))
    const drawer = screen.getByRole('complementary', { name: 'Chat details' })
    expect(within(drawer).getByRole('tab', { name: 'Task' })).toHaveAttribute('aria-selected', 'true')
    const stages = within(drawer).getByRole('list', { name: 'Stages' })
    expect(within(stages).getAllByRole('listitem').map((item) => item.textContent)).toEqual(['Plan, done', 'Build, current', 'Review, not started', 'Merge, not started'])
    expect(within(drawer).getByText('saturn/hamburger-menu')).toBeInTheDocument()
    expect(within(drawer).getByText('from main')).toBeInTheDocument()
    expect(within(drawer).getByText('App runs from the Mac')).toBeInTheDocument()
    expect(within(drawer).getByText('make dev')).toBeInTheDocument()
    const changes = within(drawer).getByRole('region', { name: 'Changes' })
    await waitFor(() => expect(within(changes).getByText('src/Hamburger.tsx')).toBeInTheDocument())
    expect(within(changes).getByText('· 7 files')).toBeInTheDocument()
    const checks = within(drawer).getByRole('region', { name: 'Checks' })
    expect(within(checks).getByText('5 of 5 passed')).toBeInTheDocument()
    expect(within(checks).getByText('E2E · mobile')).toBeInTheDocument()
    expect(within(checks).getByText('1m 12s')).toBeInTheDocument()
    const workers = within(drawer).getByRole('region', { name: 'Workers' })
    expect(within(workers).getByText('Front-end Dev')).toBeInTheDocument()
    expect(within(workers).getByText('Reviewer')).toBeInTheDocument()
    expect(within(drawer).getByRole('button', { name: 'Push' })).toBeDisabled()
    expect(within(drawer).queryByText('Open PR')).not.toBeInTheDocument()
    expect(screen.queryByText('Usage')).not.toBeInTheDocument()
    expect(screen.queryByText('Settings')).not.toBeInTheDocument()
  })

  it('pushes a finished, unmerged run with run.push', async () => {
    server = await startFixture({ 'run.push': () => 'Pushed saturn/hamburger-menu to origin.' })
    await renderApp(server)
    server.pushChanges([upsert('run', 3, {
      projectId: 1, taskId: 3, workflow: 'feature-delivery', status: 'succeeded', costUSD: 4.15, startedAt: '2026-11-25 13:44:00.000', endedAt: '2026-11-25 14:30:00.000',
      title: 'Hamburger menu for mobile', workflowSnapshot: '', engineState: '{}', deliveryBranch: 'saturn/hamburger-menu', baseBranch: 'main', filesChanged: 7, linesChanged: 210,
    })])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Open task details' }))
    const push = within(screen.getByRole('complementary', { name: 'Chat details' })).getByRole('button', { name: 'Push' })
    await waitFor(() => expect(push).toBeEnabled())
    await user.click(push)
    await waitFor(() => expect(lastCommand('run.push')?.args).toEqual({ runID: 3 }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Pushed saturn/hamburger-menu to origin.')
  })

  it('shows the Project tab: summary, stats and agents', async () => {
    server = await startFixture()
    await renderApp(server)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Open task details' }))
    const drawer = screen.getByRole('complementary', { name: 'Chat details' })
    await user.click(within(drawer).getByRole('tab', { name: 'Project' }))
    expect(within(drawer).getByRole('heading', { name: 'Project' })).toBeInTheDocument()
    expect(within(drawer).getByText('/Users/dev/code/monorepo')).toBeInTheDocument()
    expect(within(drawer).getByRole('region', { name: 'Summary' })).toHaveTextContent('4 chats and 2 runs in this project, 1 merged.')
    const stat = (label: string) => within(drawer).getByText(label).previousSibling?.textContent
    expect(stat('Active chats')).toBe('3')
    expect(stat('Needs you')).toBe('2')
    expect(stat('Finished')).toBe('1')
    expect(stat('Workers running')).toBe('0')
    const agents = within(drawer).getByRole('region', { name: 'Agents' })
    expect(within(agents).getByText('Front-end Dev')).toBeInTheDocument()
    expect(within(agents).getByText('Opus · Checker')).toBeInTheDocument()
  })

  it('shows the Log tab timeline', async () => {
    server = await startFixture()
    await renderApp(server)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Open task details' }))
    const drawer = screen.getByRole('complementary', { name: 'Chat details' })
    await user.click(within(drawer).getByRole('tab', { name: 'Log' }))
    const log = within(drawer).getByRole('log', { name: 'Chat progress' })
    const items = within(log).getAllByRole('listitem').map((item) => item.textContent)
    expect(items[0]).toContain('Chat opened in monorepo')
    expect(items.some((text) => text?.includes('Front-end Dev') && text.includes('Built the menu and the focus trap'))).toBe(true)
    expect(items.some((text) => text?.includes('Checks ✓') && text.includes('Checks · Passed'))).toBe(true)
    expect(items.some((text) => text?.includes('Approval') && text.includes('Approve the hamburger menu'))).toBe(true)
  })

  it('updates live when the run changes', async () => {
    server = await startFixture()
    await renderApp(server)
    expect(screen.getByRole('img', { name: 'Needs you' })).toBeInTheDocument()
    server.pushChanges([upsert('run', 3, {
      projectId: 1, taskId: 3, workflow: 'feature-delivery', currentStep: 'review', status: 'running', startedAt: '2026-11-25 13:44:00.000',
      title: 'Hamburger menu for mobile', workflowSnapshot: 'name: Feature delivery\nsteps:\n  - id: review\n    type: agent\n    agent: checker\n', engineState: '{}',
    }), upsert('chatRequest', 31, { projectId: 1, taskId: 3, runId: 3, kind: 'approval', title: 'Approve the hamburger menu', status: 'answered', createdAt: '2026-11-25 14:22:00.000' })])
    expect(await screen.findByRole('img', { name: 'In review' })).toBeInTheDocument()
    expect(useApp.getState().version).toBeGreaterThan(1)
  })
})
