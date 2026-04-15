package samples

type User struct {
    Name string
}

func ValidateUser(user User) bool {
    if user.Name == "" {
        return false
    }

    return true
}
