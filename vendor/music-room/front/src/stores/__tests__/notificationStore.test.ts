import { useNotificationStore } from '../../stores/notificationStore';

beforeEach(() => {
  useNotificationStore.setState({
    message: '',
    type: 'info',
    visible: false,
  });
});

describe('notificationStore', () => {
  it('should have initial hidden state', () => {
    const state = useNotificationStore.getState();
    expect(state.visible).toBe(false);
    expect(state.message).toBe('');
  });

  it('should show success notification', () => {
    useNotificationStore.getState().showSuccess('Operation completed');
    const state = useNotificationStore.getState();
    expect(state.visible).toBe(true);
    expect(state.type).toBe('success');
    expect(state.message).toBe('Operation completed');
  });

  it('should show error notification', () => {
    useNotificationStore.getState().showError('Something went wrong');
    const state = useNotificationStore.getState();
    expect(state.visible).toBe(true);
    expect(state.type).toBe('error');
    expect(state.message).toBe('Something went wrong');
  });

  it('should show info notification', () => {
    useNotificationStore.getState().showInfo('FYI message');
    const state = useNotificationStore.getState();
    expect(state.type).toBe('info');
    expect(state.message).toBe('FYI message');
  });

  it('should dismiss notification', () => {
    useNotificationStore.getState().showSuccess('Test');
    useNotificationStore.getState().dismiss();
    expect(useNotificationStore.getState().visible).toBe(false);
  });
});
