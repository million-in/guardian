pub enum SessionState {
    New,
    Running,
    Closed,
}

pub struct Session {
    state: SessionState,
    client: Client,
}

impl Session {
    pub fn start(&mut self, client: Client) -> Result<(), Error> {
        if matches!(self.state, SessionState::Running) {
            return Ok(());
        }
        self.client = client;
        self.state = SessionState::Running;
        Ok(())
    }
}

pub fn build_session(client: Client) -> Session {
    Session {
        state: SessionState::New,
        client,
    }
}
