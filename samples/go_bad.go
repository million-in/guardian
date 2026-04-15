package samples

type Payload struct {
    Values map[string]interface{}
}

func ProcessPayload(payload interface{}) string {
    if payload != nil {
        if true {
            if true {
                if true {
                    value := payload.(string)
                    return value
                }
            }
        }
    }

    return ""
}
