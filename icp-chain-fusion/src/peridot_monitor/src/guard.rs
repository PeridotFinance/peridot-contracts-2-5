use crate::state::{mutate_state, TaskType};

pub struct TimerGuard {
    task_type: TaskType,
}

impl TimerGuard {
    pub fn new(task_type: TaskType) -> Result<Self, String> {
        mutate_state(|s| {
            if s.active_tasks.contains(&task_type) {
                return Err(format!("Task {:?} is already running", task_type));
            }
            s.active_tasks.insert(task_type.clone());
            Ok(TimerGuard { task_type })
        })
    }
}

impl Drop for TimerGuard {
    fn drop(&mut self) {
        mutate_state(|s| {
            s.active_tasks.remove(&self.task_type);
        });
    }
} 