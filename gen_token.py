import jwt
import datetime
import time

def generate_jwt_token(username="Светлана", email="marinf@gmail.com", room_name="*", 
                       is_moderator=True, expires_in_hours=24):
    """
    Generate a JWT token for Jitsi Meet with moderator privileges
    
    Parameters:
    - username: User's display name
    - email: User's email
    - avatar: URL to user's avatar image
    - room_name: Room to join (use "*" for all rooms)
    - is_moderator: Whether the user should have moderator privileges
    - expires_in_hours: Token validity period in hours
    """
    # Calculate expiration time
    expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=expires_in_hours)
    
    # Create token payload
    payload = {
        "context": {
            "user": {
                "name": username,
                "email": email,
                "id": f"user-{int(time.time())}",  # Generate a unique ID based on timestamp
            }
        },
        "aud": "funcode",         # Must match JWT_ACCEPTED_AUDIENCES in .env
        "iss": "funcode",         # Must match JWT_ACCEPTED_ISSUERS in .env
        "sub": "video-by.ominds.online",
        "room": room_name,
        "exp": expiry,
        "moderator": True
    }
    
    # Sign token with secret
    token = jwt.encode(payload, 'very very secret key funcode', algorithm='HS256')
    
    return token

if __name__ == "__main__":
    # Generate a token with default values
    token = generate_jwt_token()
    print("******************************")
    print(token)